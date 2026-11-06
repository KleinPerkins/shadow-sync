import Darwin
import ShadowSyncCore

signal(SIGPIPE, SIG_IGN)
exit(LifecycleCoordinatorMain.run(arguments: CommandLine.arguments))
