import AppKit
import SwiftUI

/// The navigation bar's downloads button, which shows overall progress and lists downloads in a popover.
struct DownloadsButton: View {
    let downloads: DownloadManager
    @State private var isShowingList = false

    var body: some View {
        Button { isShowingList.toggle() } label: {
            ZStack {
                if downloads.isDownloading {
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.02, downloads.progress))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.2), value: downloads.progress)
                }
                Image(systemName: downloads.isDownloading ? "arrow.down" : "arrow.down.circle")
                    .font(.system(size: downloads.isDownloading ? 8.5 : 14, weight: .semibold))
                    .symbolEffect(.bounce, value: downloads.items.count)
            }
            .frame(width: 17, height: 17)
        }
        .buttonStyle(ChromeIconButtonStyle(size: 30))
        .help("Downloads")
        .accessibilityLabel("Downloads")
        .accessibilityValue(downloads.isDownloading ? Text(downloads.progress, format: .percent.precision(.fractionLength(0)))
                                                    : Text(""))
        .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
            DownloadsList(downloads: downloads)
        }
    }
}

private struct DownloadsList: View {
    let downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") { downloads.clearFinished() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .disabled(!downloads.items.contains { $0.state != .downloading })
                    .help("Remove finished downloads from the list")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(downloads.items) { item in
                        DownloadRow(item: item, downloads: downloads)
                    }
                }
                .padding([.horizontal, .bottom], 6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 320)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let downloads: DownloadManager
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            icon
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .downloading {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(item.state == .failed ? Color.red : Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.state == .downloading {
                Button { downloads.cancel(item) } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(ChromeIconButtonStyle(size: 24))
                .help("Cancel Download")
                .accessibilityLabel("Cancel \(item.name)")
            } else if item.state == .finished {
                Button { downloads.reveal(item) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(ChromeIconButtonStyle(size: 24))
                .help("Show in Finder")
                .accessibilityLabel("Show \(item.name) in Finder")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) { downloads.open(item) }
        .contextMenu {
            Button("Open") { downloads.open(item) }
                .disabled(item.state != .finished)
            Button("Show in Finder") { downloads.reveal(item) }
                .disabled(item.state != .finished)
            if item.state == .downloading {
                Divider()
                Button("Cancel Download") { downloads.cancel(item) }
            }
        }
        .help(item.state == .finished ? "Double-click to open" : "")
    }

    @ViewBuilder
    private var icon: some View {
        if item.state == .finished, let url = item.destinationURL {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "doc")
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.secondary)
        }
    }

    private var status: String {
        let completed = item.completedBytes.formatted(.byteCount(style: .file))
        switch item.state {
        case .downloading:
            guard item.totalBytes > 0 else { return completed }
            return "\(completed) of \(item.totalBytes.formatted(.byteCount(style: .file)))"
        case .finished: return completed
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }
}
