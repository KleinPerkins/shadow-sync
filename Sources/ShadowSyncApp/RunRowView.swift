import AppKit
import ShadowSyncCore

@MainActor
final class RunRowView: NSView {
    private let symbolView = NSImageView()
    private let identityLabel = NSTextField(wrappingLabelWithString: "")
    private let pathLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let separator = NSBox()
    private(set) var presentation: RunRowPresentation
    #if SHADOW_SYNC_TESTING
    private(set) var testingUpdateCount = 0
    #endif

    init(presentation: RunRowPresentation) {
        self.presentation = presentation
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildContent()
        update(presentation)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func buildContent() {
        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let bodySize = NSFont.preferredFont(forTextStyle: .body).pointSize
        identityLabel.font = NSFont.systemFont(ofSize: bodySize, weight: .semibold)
        identityLabel.maximumNumberOfLines = 0
        identityLabel.lineBreakMode = .byCharWrapping
        pathLabel.font = .preferredFont(forTextStyle: .caption1)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.maximumNumberOfLines = 0
        pathLabel.lineBreakMode = .byCharWrapping
        statusLabel.font = .preferredFont(forTextStyle: .body)
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 0
        detailLabel.lineBreakMode = .byCharWrapping
        for label in [identityLabel, pathLabel, statusLabel, detailLabel] {
            label.setContentCompressionResistancePriority(
                .defaultLow,
                for: .horizontal
            )
        }
        textStack.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )

        textStack.addArrangedSubview(identityLabel)
        textStack.addArrangedSubview(pathLabel)

        let statusStack = NSStackView()
        statusStack.orientation = .horizontal
        statusStack.alignment = .centerY
        statusStack.spacing = 7
        statusStack.translatesAutoresizingMaskIntoConstraints = false
        statusStack.setContentCompressionResistancePriority(
            .defaultLow,
            for: .horizontal
        )
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(
            textStyle: .body,
            scale: .medium
        )
        symbolView.contentTintColor = .labelColor
        symbolView.setContentHuggingPriority(.required, for: .horizontal)
        statusStack.addArrangedSubview(symbolView)
        statusStack.addArrangedSubview(statusLabel)
        statusLabel.lineBreakMode = .byCharWrapping
        statusLabel.maximumNumberOfLines = 0
        textStack.addArrangedSubview(statusStack)
        statusStack.widthAnchor.constraint(
            equalTo: textStack.widthAnchor
        ).isActive = true
        textStack.addArrangedSubview(detailLabel)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)
        addSubview(separator)

        NSLayoutConstraint.activate([
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            separator.topAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 9),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren([
            identityLabel,
            pathLabel,
            symbolView,
            statusLabel,
            detailLabel,
        ])
    }

    func update(_ presentation: RunRowPresentation) {
        precondition(presentation.repository == self.presentation.repository)
        self.presentation = presentation
        #if SHADOW_SYNC_TESTING
        testingUpdateCount += 1
        #endif
        let originName = RepositoryOperatorPresentation.primaryName(
            presentation.repository
        )
        identityLabel.stringValue = originName
        pathLabel.stringValue = presentation.showsLocation
            ? RepositoryOperatorPresentation.secondaryLocation(
                presentation.repository
            ) ?? ""
            : ""
        pathLabel.isHidden = pathLabel.stringValue.isEmpty
        statusLabel.stringValue = presentation.status.label
        detailLabel.stringValue = presentation.detailText
        detailLabel.isHidden = presentation.detailText.isEmpty

        let symbol = ShadowSyncStatusSymbol.rowStatus(presentation.status)
        symbolView.image = NSImage(
            systemSymbolName: symbol.name,
            accessibilityDescription: symbol.description
        )
        symbolView.setAccessibilityLabel(symbol.description)
        statusLabel.setAccessibilityLabel("Status")
        statusLabel.setAccessibilityValue(presentation.status.label)
        setAccessibilityLabel(originName)
        setAccessibilityValue(presentation.accessibilityValue)
    }

    #if SHADOW_SYNC_TESTING
    var testingSymbolDescription: String? {
        symbolView.image?.accessibilityDescription
    }

    var testingStatusText: String {
        statusLabel.stringValue
    }

    var testingIdentityText: String {
        identityLabel.stringValue
    }

    var testingPathText: String {
        pathLabel.stringValue
    }

    var testingDetailText: String {
        detailLabel.stringValue
    }

    var testingUsesSemanticColors: Bool {
        pathLabel.textColor == .secondaryLabelColor
            && detailLabel.textColor == .secondaryLabelColor
            && symbolView.contentTintColor == .labelColor
    }

    var testingSupportsWrapping: Bool {
        identityLabel.maximumNumberOfLines == 0
            && identityLabel.lineBreakMode == .byCharWrapping
            && pathLabel.maximumNumberOfLines == 0
            && pathLabel.lineBreakMode == .byCharWrapping
            && detailLabel.maximumNumberOfLines == 0
            && detailLabel.lineBreakMode == .byCharWrapping
    }
    #endif
}
