import SwiftUI

/// Represents the current state of the application
enum AppState: Equatable {
    case idle
    case converting(inputURL: URL, progress: Double, statusMessage: String)
    case completed(outputURL: URL)
    case error(message: String, fullOutput: String)

    static func == (lhs: AppState, rhs: AppState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case let (.converting(lURL, lProgress, lMsg), .converting(rURL, rProgress, rMsg)):
            return lURL == rURL && lProgress == rProgress && lMsg == rMsg
        case let (.completed(lURL), .completed(rURL)):
            return lURL == rURL
        case let (.error(lMsg, lOut), .error(rMsg, rOut)):
            return lMsg == rMsg && lOut == rOut
        default:
            return false
        }
    }
}

/// Main content view that manages application state and displays appropriate screens
struct ContentView: View {
    /// Current application state
    @State private var appState: AppState = .idle
    
    /// Current input URL being converted
    @State private var currentInputURL: URL?
    
    /// The GIF converter service (shared with debug window)
    @EnvironmentObject private var converter: GifConverter
    
    /// Settings manager
    @ObservedObject private var settings = SettingsManager.shared
    
    /// Environment actions for window management
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 0) {
            // Draggable area at top (replaces title bar)
            DraggableArea()
                .frame(height: 28)
            
            // Main content
            Group {
                switch appState {
                case .idle:
                    DropZoneView(onVideoSelected: startConversion)
                    
                case .converting(let inputURL, let progress, let statusMessage):
                    ConversionView(
                        inputURL: inputURL,
                        progress: progress,
                        statusMessage: statusMessage,
                        onCancel: cancelConversion
                    )
                    
                case .completed(let outputURL):
                    CompletionView(
                        outputURL: outputURL,
                        onConvertAnother: resetToIdle,
                        onVideoSelected: startConversion
                    )
                    
                case .error(let message, let fullOutput):
                    ErrorView(
                        error: ConversionError(message: message, fullOutput: fullOutput),
                        onTryAgain: resetToIdle,
                        onVideoSelected: startConversion
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Status bar at bottom
            StatusBar(settings: settings)
        }
        .frame(minWidth: 400, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            converter.isDebugEnabled = settings.debugModeEnabled
            // Open debug window if debug mode was already enabled
            if settings.debugModeEnabled {
                openWindow(id: "debug-window")
            }
        }
        .onChange(of: settings.debugModeEnabled) { newValue in
            converter.isDebugEnabled = newValue
            // Open or close debug window based on mode
            if newValue {
                openWindow(id: "debug-window")
            } else {
                // Close debug window using NSApplication (macOS 13 compatible)
                closeDebugWindow()
            }
        }
        .onChange(of: settings.showDebugWindowTrigger) { _ in
            // Open debug window when triggered from menu
            if settings.debugModeEnabled {
                openWindow(id: "debug-window")
            }
        }
        .onChange(of: settings.showAboutWindowTrigger) { _ in
            // Open about window when triggered from menu
            openWindow(id: "about-window")
        }
    }
    
    /// Start converting a video file
    private func startConversion(inputURL: URL) {
        currentInputURL = inputURL
        appState = .converting(inputURL: inputURL, progress: 0, statusMessage: "Preparing…")

        let outputDirectory = settings.outputDirectory(for: inputURL)
        let outputURL = FileNaming.uniqueOutputURL(for: inputURL, in: outputDirectory)

        Task {
            do {
                let result = try await converter.convert(
                    input: inputURL,
                    output: outputURL
                ) { progress in
                    self.appState = .converting(
                        inputURL: inputURL,
                        progress: progress.percentage,
                        statusMessage: progress.statusMessage
                    )
                }
                appState = .completed(outputURL: result)
            } catch let error as ConversionError {
                appState = .error(message: error.message, fullOutput: error.fullOutput)
            } catch {
                appState = .error(message: error.localizedDescription, fullOutput: error.localizedDescription)
            }
        }
    }
    
    private func cancelConversion() {
        converter.cancel()
        resetToIdle()
    }
    
    private func resetToIdle() {
        appState = .idle
        currentInputURL = nil
    }
    
    /// Close the debug window using NSApplication (macOS 13 compatible)
    private func closeDebugWindow() {
        for window in NSApplication.shared.windows {
            if window.title == "FFmpeg Debug Output" {
                window.close()
                break
            }
        }
    }
}

// MARK: - Draggable Area (replaces title bar)

struct DraggableArea: View {
    var body: some View {
        HStack {
            // Window controls area (traffic lights appear here automatically)
            Spacer()
            
            // App title
            Text("Video to GIF")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(WindowDragArea())
    }
}

/// NSView-based draggable area for window movement
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DraggableNSView()
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}

class DraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    @ObservedObject var settings: SettingsManager
    @State private var showFolderPicker = false
    
    var body: some View {
        HStack(spacing: 12) {
            // Location dropdown
            LocationDropdown(settings: settings, showFolderPicker: $showFolderPicker)
            
            Divider()
                .frame(height: 12)
            
            // FPS dropdown
            FPSDropdown(settings: settings)
            
            Divider()
                .frame(height: 12)
            
            // Resolution dropdown
            ResolutionDropdown(settings: settings)
            
            Spacer(minLength: 0)
            
            // Debug mode indicator (clickable)
            DebugToggle(settings: settings)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 28)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(Color(nsColor: .separatorColor)),
            alignment: .top
        )
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                settings.setCustomOutputPath(url)
                settings.saveToSameFolder = false
            }
        }
        .modifier(HideFocusRingModifier())
    }
}

// MARK: - Hide Focus Ring Modifier

struct HideFocusRingModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content
                .focusEffectDisabled()
        } else {
            content
        }
    }
}

// MARK: - Location Dropdown

struct LocationDropdown: View {
    @ObservedObject var settings: SettingsManager
    @Binding var showFolderPicker: Bool
    
    var body: some View {
        Menu {
            // Same folder option
            Toggle(isOn: Binding(
                get: { settings.saveToSameFolder },
                set: { if $0 { settings.saveToSameFolder = true } }
            )) {
                Text("Same folder as video")
            }
            
            Divider()
            
            // Recent locations
            if !settings.recentLocations.isEmpty {
                ForEach(settings.recentLocations, id: \.path) { url in
                    Toggle(isOn: Binding(
                        get: { !settings.saveToSameFolder && settings.customOutputPath == url.path },
                        set: { if $0 {
                            settings.saveToSameFolder = false
                            settings.customOutputPath = url.path
                        }}
                    )) {
                        Text(url.lastPathComponent)
                    }
                }
                
                Divider()
                
                Button("Clear Recent") {
                    settings.clearRecentLocations()
                }
                
                Divider()
            }
            
            // Browse option
            Button {
                showFolderPicker = true
            } label: {
                Text("Browse...")
            }
        } label: {
            StatusItemLabel(
                icon: "folder",
                text: locationText
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private var locationText: String {
        if settings.saveToSameFolder {
            return "Same folder"
        } else {
            let path = settings.customOutputURL.lastPathComponent
            return path.isEmpty ? "Desktop" : path
        }
    }
}

// MARK: - FPS Dropdown

struct FPSDropdown: View {
    @ObservedObject var settings: SettingsManager
    
    var body: some View {
        Menu {
            // Relative section
            Section("Relative to original") {
                fpsRelativeToggle(0.25, label: "0.25× (quarter)")
                fpsRelativeToggle(0.5, label: "0.5× (half)")
                fpsRelativeToggle(0.75, label: "0.75×")
                fpsRelativeToggle(1.0, label: "1× (same as original)")
                fpsRelativeToggle(1.5, label: "1.5×")
                fpsRelativeToggle(2.0, label: "2× (double)")
            }
            
            Divider()
            
            // Fixed section
            Section("Fixed value") {
                fpsFixedToggle(10)
                fpsFixedToggle(15)
                fpsFixedToggle(20)
                fpsFixedToggle(25)
                fpsFixedToggle(30)
                fpsFixedToggle(60)
            }
        } label: {
            StatusItemLabel(
                icon: "film",
                text: fpsText
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private func fpsRelativeToggle(_ value: Double, label: String) -> some View {
        Toggle(isOn: Binding(
            get: { settings.frameRateMode == .relative && settings.relativeFrameRate == value },
            set: { if $0 {
                settings.frameRateMode = .relative
                settings.relativeFrameRate = value
            }}
        )) {
            Text(label)
        }
    }
    
    private func fpsFixedToggle(_ value: Int) -> some View {
        Toggle(isOn: Binding(
            get: { settings.frameRateMode == .fixed && settings.fixedFrameRate == value },
            set: { if $0 {
                settings.frameRateMode = .fixed
                settings.fixedFrameRate = value
            }}
        )) {
            Text("\(value) fps")
        }
    }
    
    private var fpsText: String {
        switch settings.frameRateMode {
        case .fixed:
            return "\(settings.fixedFrameRate) fps"
        case .relative:
            if settings.relativeFrameRate == 1.0 {
                return "1× fps"
            }
            return "\(formatMultiplier(settings.relativeFrameRate)) fps"
        }
    }
    
    private func formatMultiplier(_ value: Double) -> String {
        if value == floor(value) {
            return String(format: "%.0f×", value)
        } else {
            return String(format: "%.2g×", value)
        }
    }
}

// MARK: - Resolution Dropdown

struct ResolutionDropdown: View {
    @ObservedObject var settings: SettingsManager
    
    var body: some View {
        Menu {
            // Relative section
            Section("Relative to original") {
                resolutionRelativeToggle(0.25, label: "0.25× (quarter)")
                resolutionRelativeToggle(0.5, label: "0.5× (half)")
                resolutionRelativeToggle(0.75, label: "0.75×")
                resolutionRelativeToggle(1.0, label: "1× (same as original)")
                resolutionRelativeToggle(1.25, label: "1.25×")
                resolutionRelativeToggle(1.5, label: "1.5×")
                resolutionRelativeToggle(2.0, label: "2× (double)")
            }
            
            Divider()
            
            // Fixed section
            Section("Fixed width") {
                resolutionFixedToggle(320)
                resolutionFixedToggle(480)
                resolutionFixedToggle(640)
                resolutionFixedToggle(800)
                resolutionFixedToggle(1024)
                resolutionFixedToggle(1280)
                resolutionFixedToggle(1920)
            }
        } label: {
            StatusItemLabel(
                icon: "aspectratio",
                text: resolutionText
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
    
    private func resolutionRelativeToggle(_ value: Double, label: String) -> some View {
        Toggle(isOn: Binding(
            get: { settings.resolutionMode == .relative && settings.relativeResolution == value },
            set: { if $0 {
                settings.resolutionMode = .relative
                settings.relativeResolution = value
            }}
        )) {
            Text(label)
        }
    }
    
    private func resolutionFixedToggle(_ value: Int) -> some View {
        Toggle(isOn: Binding(
            get: { settings.resolutionMode == .fixed && settings.fixedWidth == value },
            set: { if $0 {
                settings.resolutionMode = .fixed
                settings.fixedWidth = value
            }}
        )) {
            Text("\(value)px")
        }
    }
    
    private var resolutionText: String {
        switch settings.resolutionMode {
        case .fixed:
            return "\(settings.fixedWidth)px"
        case .relative:
            if settings.relativeResolution == 1.0 {
                return "1× size"
            }
            return "\(formatMultiplier(settings.relativeResolution)) size"
        }
    }
    
    private func formatMultiplier(_ value: Double) -> String {
        if value == floor(value) {
            return String(format: "%.0f×", value)
        } else {
            return String(format: "%.2g×", value)
        }
    }
}

// MARK: - Debug Toggle

struct DebugToggle: View {
    @ObservedObject var settings: SettingsManager
    
    var body: some View {
        Button {
            settings.debugModeEnabled.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "ladybug")
                    .font(.system(size: 10))
                if settings.debugModeEnabled {
                    Text("Debug")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .foregroundColor(settings.debugModeEnabled ? .orange : .secondary.opacity(0.5))
        }
        .buttonStyle(.plain)
        .help(settings.debugModeEnabled ? "Debug mode on (click to disable)" : "Debug mode off (click to enable)")
    }
}

// MARK: - Status Item Label

struct StatusItemLabel: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 8))
                .opacity(0.6)
        }
        .foregroundColor(.secondary)
    }
}

#Preview {
    ContentView()
        .environmentObject(GifConverter())
}
