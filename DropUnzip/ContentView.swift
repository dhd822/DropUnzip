import SwiftUI
import UniformTypeIdentifiers

// Known archive extensions — dropping these triggers extraction
private let archiveExtensions: Set<String> = [
    "zip", "gz", "tgz", "tar", "bz2", "xz", "7z", "rar", "cpgz", "z", "lz", "lzma"
]

// ── Brand palette (pulled from the icon) ─────────────────────────────────────
private extension Color {
    static let brand       = Color(red: 1.00, green: 0.86, blue: 0.47)  // warm yellow
    static let brandPink   = Color(red: 1.00, green: 0.63, blue: 0.71)  // soft pink
    static let brandBlue   = Color(red: 0.63, green: 0.78, blue: 0.94)  // light blue
    static let brandDark   = Color(red: 0.13, green: 0.13, blue: 0.18)  // near-black
    static let brandSurface = Color(red: 0.17, green: 0.17, blue: 0.23) // card bg
}

struct ContentView: View {
    @StateObject private var extractor = Extractor()
    @StateObject private var compressor = Compressor()
    @State private var isTargeted = false

    private var activeMode: ActiveMode {
        switch compressor.state {
        case .pickingFormat, .compressing, .success, .failure: return .compress
        default:
            switch extractor.state {
            case .idle: return .idle
            default:    return .extract
            }
        }
    }

    var body: some View {
        ZStack {
            // ── Gradient background ───────────────────────────────────────
            LinearGradient(
                colors: [Color.brandDark, Color(red: 0.10, green: 0.10, blue: 0.16)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            // ── Subtle glow behind drop zone when targeted ────────────────
            if isTargeted {
                RadialGradient(
                    colors: [Color.brand.opacity(0.25), .clear],
                    center: .center, startRadius: 10, endRadius: 220
                )
                .blur(radius: 20)
                .animation(.easeInOut(duration: 0.2), value: isTargeted)
            }

            // ── Drop zone card ────────────────────────────────────────────
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.brandSurface.opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(
                            isTargeted
                                ? Color.brand
                                : Color.white.opacity(0.08),
                            style: StrokeStyle(
                                lineWidth: isTargeted ? 2.5 : 1.5,
                                dash: isTargeted ? [] : [10, 6]
                            )
                        )
                )
                .shadow(color: .black.opacity(0.4), radius: 24, x: 0, y: 8)
                .animation(.easeInOut(duration: 0.2), value: isTargeted)

            // ── Content ───────────────────────────────────────────────────
            VStack(spacing: 0) {
                switch activeMode {
                case .idle:    idleView
                case .extract: extractionContent
                case .compress: compressionContent
                }
            }
            .padding(28)
        }
        .frame(width: 440, height: 340)
        .padding(14)
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - Idle ─────────────────────────────────────────────────────────────

    private var idleView: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(
                        isTargeted
                            ? Color.brand.opacity(0.2)
                            : Color.white.opacity(0.06)
                    )
                    .frame(width: 88, height: 88)
                    .animation(.easeInOut(duration: 0.2), value: isTargeted)

                Image(systemName: isTargeted ? "arrow.down.circle.fill" : "archivebox.fill")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundStyle(isTargeted ? Color.brand : Color.white.opacity(0.7))
                    .scaleEffect(isTargeted ? 1.12 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isTargeted)
            }

            Text(isTargeted ? "Release to Continue" : "Drop Files Here")
                .font(.title2.weight(.semibold))
                .foregroundStyle(isTargeted ? Color.brand : .white)
                .animation(.easeInOut(duration: 0.15), value: isTargeted)

            // Two-pill hint row
            HStack(spacing: 10) {
                modePill(icon: "arrow.up.bin.fill", label: "Extract", color: .brandBlue)
                modePill(icon: "doc.badge.plus",    label: "Compress", color: .brandPink)
            }

            Text(".zip · .tar · .gz · .bz2 · .xz · .7z · .rar")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Color.white.opacity(0.75))
                .padding(.top, 2)
        }
    }

    private func modePill(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(color.opacity(0.15), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Extraction ───────────────────────────────────────────────────────

    @ViewBuilder
    private var extractionContent: some View {
        switch extractor.state {
        case .idle: EmptyView()
        case .extracting(let filename, let progress, let currentFile):
            progressView(label: "Extracting", filename: filename,
                         progress: progress, currentFile: currentFile,
                         accentColor: .brandBlue)
        case .success(let result):
            successView(
                icon: "arrow.up.bin.fill",
                iconColor: .brandBlue,
                title: "Extracted",
                outputName: result.outputName,
                destinationPath: result.destinationPath
            ) {
                if result.fullPath != result.destinationPath {
                    NSWorkspace.shared.selectFile(result.fullPath, inFileViewerRootedAtPath: "")
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: result.destinationPath))
                }
            } onDone: { extractor.reset() }
        case .failure(let message):
            failureView(message: message) { extractor.reset() }
        }
    }

    // MARK: - Compression ──────────────────────────────────────────────────────

    @ViewBuilder
    private var compressionContent: some View {
        switch compressor.state {
        case .idle: EmptyView()
        case .pickingFormat(let urls):
            formatPickerView(urls: urls)
        case .compressing(let filename, let progress, let currentFile):
            progressView(label: "Compressing", filename: filename,
                         progress: progress, currentFile: currentFile,
                         accentColor: .brandPink)
        case .success(let result):
            successView(
                icon: "doc.zipper",
                iconColor: .brandPink,
                title: "Compressed",
                outputName: result.outputName,
                destinationPath: result.destinationPath
            ) {
                NSWorkspace.shared.selectFile(result.outputPath, inFileViewerRootedAtPath: "")
            } onDone: { compressor.reset() }
        case .failure(let message):
            failureView(message: message) { compressor.reset() }
        }
    }

    // MARK: - Format picker ────────────────────────────────────────────────────

    private func formatPickerView(urls: [URL]) -> some View {
        VStack(spacing: 14) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.plus")
                    .foregroundStyle(Color.brandPink)
                    .font(.title3.weight(.semibold))
                let names = urls.prefix(2).map(\.lastPathComponent).joined(separator: ", ")
                let suffix = urls.count > 2 ? " +\(urls.count - 2) more" : ""
                Text("\(names)\(suffix)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))

            Text("Choose a compression format")
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.45))

            // 2×2 format grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(CompressFormat.allCases) { format in
                    formatButton(format: format, urls: urls)
                }
            }

            Button("Cancel") { compressor.reset() }
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.35))
                .buttonStyle(.plain)
        }
    }

    private func formatButton(format: CompressFormat, urls: [URL]) -> some View {
        let colors: [CompressFormat: Color] = [
            .zip:    .brandBlue,
            .tarGz:  .brandPink,
            .tarBz2: .brand,
            .tarXz:  Color(red: 0.72, green: 0.60, blue: 0.95),
        ]
        let color = colors[format] ?? .white

        return Button {
            compressor.compress(urls: urls, format: format)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: format.icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(color)
                Text(format.label)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                Text(format.description)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared: Progress ─────────────────────────────────────────────────

    private func progressView(label: String, filename: String,
                               progress: Double, currentFile: String,
                               accentColor: Color) -> some View {
        VStack(spacing: 16) {
            // Animated icon
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: label == "Extracting" ? "arrow.up.bin.fill" : "doc.zipper")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(accentColor)
            }

            VStack(spacing: 4) {
                Text(label + "…")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(filename)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 360)
            }

            // Progress bar
            VStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 8)

                    if progress > 0 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(
                                LinearGradient(
                                    colors: [accentColor, accentColor.opacity(0.7)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(width: max(8, 360 * progress), height: 8)
                            .animation(.linear(duration: 0.12), value: progress)
                    } else {
                        // Indeterminate shimmer
                        IndeterminateBar(color: accentColor)
                    }
                }
                .frame(width: 360, height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                HStack {
                    Text(currentFile.isEmpty ? "Starting…" : currentFile)
                        .font(.caption2)
                        .foregroundStyle(Color.white.opacity(0.35))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if progress > 0 {
                        Text("\(Int(progress * 100))%")
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .foregroundStyle(accentColor)
                    }
                }
                .frame(width: 360)
            }
        }
    }

    // MARK: - Shared: Success ──────────────────────────────────────────────────

    private func successView(icon: String, iconColor: Color,
                              title: String, outputName: String,
                              destinationPath: String,
                              onReveal: @escaping () -> Void,
                              onDone: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 80, height: 80)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            VStack(spacing: 4) {
                Text(title + " Successfully")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)

                Text(outputName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 340)

                Text(destinationPath)
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.35))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 340)
            }

            HStack(spacing: 12) {
                Button(action: onReveal) {
                    Label("Show in Finder", systemImage: "folder")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.brandDark)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(iconColor, in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                Button(action: onDone) {
                    Text("Done")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Shared: Failure ──────────────────────────────────────────────────

    private func failureView(message: String, onRetry: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.red.opacity(0.85))
            }

            Text("Something went wrong")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text(message)
                .font(.caption)
                .foregroundStyle(Color.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)

            Button(action: onRetry) {
                Text("Try Again")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.brandDark)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Drop handling ────────────────────────────────────────────────────

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var resolved: URL?
                if let url = item as? URL { resolved = url }
                else if let data = item as? Data { resolved = URL(dataRepresentation: data, relativeTo: nil) }
                else if let string = item as? String { resolved = URL(fileURLWithPath: string) }
                if let url = resolved { urls.append(url.resolvingSymlinksInPath()) }
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            self.route(urls: urls)
        }
        return true
    }

    private func route(urls: [URL]) {
        if urls.count == 1,
           archiveExtensions.contains(urls[0].pathExtension.lowercased()) {
            extractor.extract(url: urls[0])
        } else {
            compressor.promptFormat(for: urls)
        }
    }
}

// MARK: - Indeterminate shimmer bar ───────────────────────────────────────────

struct IndeterminateBar: View {
    let color: Color
    @State private var offset: CGFloat = -120

    var body: some View {
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 4)
                .fill(
                    LinearGradient(
                        colors: [.clear, color.opacity(0.8), .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(width: 120)
                .offset(x: offset)
                .onAppear {
                    withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                        offset = geo.size.width + 120
                    }
                }
        }
        .clipped()
    }
}

private enum ActiveMode { case idle, extract, compress }

#Preview {
    ContentView()
}
