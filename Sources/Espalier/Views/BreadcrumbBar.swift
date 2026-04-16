import SwiftUI
import EspalierKit

struct BreadcrumbBar: View {
    let repoName: String?
    let branchName: String?
    let path: String?

    var body: some View {
        HStack(spacing: 4) {
            if let repoName {
                Text(repoName)
                    .foregroundColor(.secondary)
            }
            if branchName != nil {
                Text("/")
                    .foregroundColor(.secondary.opacity(0.5))
            }
            if let branchName {
                Text(branchName)
                    .foregroundColor(.accentColor)
            }
            Spacer()
            if let path {
                Text(path)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }
}
