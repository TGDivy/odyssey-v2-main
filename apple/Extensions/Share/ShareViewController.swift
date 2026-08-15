import UIKit

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let titleLabel = UILabel()
        titleLabel.text = "Capture to Odyssey"
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let messageLabel = UILabel()
        messageLabel.text = "Open Odyssey to review and save the shared item locally."
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0

        let openButton = UIButton(type: .system)
        openButton.setTitle("Continue", for: .normal)
        openButton.addTarget(self, action: #selector(complete), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, openButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func complete() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}

