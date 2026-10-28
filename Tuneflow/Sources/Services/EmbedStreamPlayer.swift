import Foundation
import WebKit
import Combine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Fallback playback through the official YouTube IFrame Player API inside a WKWebView.
///
/// The primary playback path is AVPlayer with a direct stream (see `AudioPlayerService`).
/// This engine is only used when that resolution fails. Commands issued before the
/// iframe API is ready are queued, and failures are reported through `errorHandler`
/// instead of being silently dropped.
public final class EmbedStreamPlayer: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = EmbedStreamPlayer()

    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var currentVideoId: String? = nil

    private var webView: WKWebView?
    private var pendingVideoId: String?
    private var isPlayingHandler: ((Bool) -> Void)?
    private var timeUpdateHandler: ((Double, Double) -> Void)?
    private var endHandler: (() -> Void)?
    public var errorHandler: ((String) -> Void)?

    private override init() {
        super.init()
        setupWebView()
    }

    private func setupWebView() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.webView != nil { return }

            let config = WKWebViewConfiguration()
            #if os(iOS)
            config.allowsInlineMediaPlayback = true
            config.allowsPictureInPictureMediaPlayback = true
            #endif
            config.mediaTypesRequiringUserActionForPlayback = []

            let ucc = WKUserContentController()
            ucc.add(self, name: "playerCallback")
            config.userContentController = ucc

            // Must be >= 200x200 or YouTube refuses to play.
            let wv = WKWebView(frame: CGRect(x: -1000, y: -1000, width: 220, height: 220), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
            #if os(iOS)
            wv.isOpaque = false
            wv.backgroundColor = .clear
            wv.isUserInteractionEnabled = false
            wv.alpha = 0.01
            #else
            wv.alphaValue = 0.01
            #endif

            self.webView = wv
            self.attachToWindow(wv)
            self.loadPlayerHTML()

            if let pending = self.pendingVideoId {
                self.pendingVideoId = nil
                self.playVideo(videoId: pending)
            }
        }
    }

    /// A detached WKWebView can be suspended (and then YouTube never starts).
    /// Park it offscreen inside the app's window instead.
    private func attachToWindow(_ wv: WKWebView) {
        #if os(iOS)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.attachToWindow(wv)
            }
            return
        }
        if wv.superview !== window {
            window.addSubview(wv)
            window.sendSubviewToBack(wv)
        }
        #elseif os(macOS)
        guard let window = NSApplication.shared.keyWindow
                ?? NSApplication.shared.mainWindow
                ?? NSApplication.shared.windows.first(where: { $0.isVisible }) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.attachToWindow(wv)
            }
            return
        }
        if wv.superview !== window.contentView {
            wv.frame = CGRect(x: -1000, y: -1000, width: 220, height: 220)
            wv.autoresizingMask = []
            window.contentView?.addSubview(wv)
        }
        #endif
    }

    private func loadPlayerHTML() {
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>body,html{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}#player{width:100%;height:100%}</style>
        </head><body><div id="player"></div>
        <script>
        var player = null, apiReady = false, playerReady = false, queuedVideo = null, commandQueue = [], tracker = null;
        function post(o){ try { window.webkit.messageHandlers.playerCallback.postMessage(o); } catch (e) {} }

        function onYouTubeIframeAPIReady(){
            apiReady = true;
            post({event:'ready'});
            if (queuedVideo) { var v = queuedVideo; queuedVideo = null; loadAndPlay(v); }
        }
        window.onYouTubeIframeAPIReady = onYouTubeIframeAPIReady;

        var tag = document.createElement('script');
        tag.src = "https://www.youtube.com/iframe_api";
        tag.onerror = function(){ post({event:'fatal', message:'Could not load the YouTube player script.'}); };
        document.head.appendChild(tag);

        setTimeout(function(){
            if (!apiReady) post({event:'fatal', message:'The YouTube player did not load (timed out).'});
        }, 12000);

        function currentOrigin(){
            var o = (window.location && window.location.origin) ? window.location.origin : '';
            return (o && o !== 'null') ? o : 'https://www.youtube.com';
        }

        function loadAndPlay(videoId){
            if (!apiReady) { queuedVideo = videoId; return; }
            if (player && player.loadVideoById) {
                player.loadVideoById(videoId);
                try { player.playVideo(); } catch (e) {}
                return;
            }
            player = new YT.Player('player', {
                height:'100%', width:'100%', videoId: videoId,
                playerVars:{playsinline:1, controls:0, autoplay:1, rel:0, enablejsapi:1, origin:currentOrigin()},
                events:{ onReady:onPlayerReady, onStateChange:onPlayerStateChange, onError:onPlayerError }
            });
        }

        function onPlayerReady(e){
            playerReady = true;
            try { e.target.playVideo(); } catch (err) {}
            startTracker();
            flushCommands();
        }
        function onPlayerStateChange(e){ post({event:'stateChange', state:e.data}); }
        function onPlayerError(e){ post({event:'error', code:e.data}); }
        function startTracker(){
            if (tracker) return;
            tracker = setInterval(function(){
                if (player && player.getCurrentTime) {
                    try { post({event:'timeUpdate', current:player.getCurrentTime(), duration:player.getDuration()}); } catch (err) {}
                }
            }, 500);
        }
        function flushCommands(){
            while (commandQueue.length) { applyCommand(commandQueue.shift()); }
        }
        function applyCommand(cmd){
            if (!player) return;
            try {
                if (cmd === 'play') player.playVideo();
                else if (cmd === 'pause') player.pauseVideo();
                else if (cmd.indexOf('seek:') === 0) player.seekTo(parseFloat(cmd.slice(5)), true);
            } catch (err) { post({event:'fatal', message:String(err)}); }
        }
        function runCommand(cmd){
            if (!player) { commandQueue.push(cmd); return; }
            applyCommand(cmd);
        }
        function playAudio(){ runCommand('play'); }
        function pauseAudio(){ runCommand('pause'); }
        function seekAudio(s){ runCommand('seek:' + s); }
        </script></body></html>
        """
        webView?.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }

    public func setCallbacks(
        onPlayingChange: @escaping (Bool) -> Void,
        onTimeUpdate: @escaping (Double, Double) -> Void,
        onEnded: @escaping () -> Void
    ) {
        isPlayingHandler = onPlayingChange
        timeUpdateHandler = onTimeUpdate
        endHandler = onEnded
    }

    public func playVideo(videoId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.webView == nil {
                self.pendingVideoId = videoId
                self.setupWebView()
                return
            }
            self.currentVideoId = videoId
            let safe = videoId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            self.webView?.evaluateJavaScript("loadAndPlay('\(safe)');", completionHandler: nil)
        }
    }

    public func play()  { run("playAudio();") }
    public func pause() { run("pauseAudio();") }
    public func seek(to seconds: Double) { run("seekAudio(\(seconds));") }
    public func stop() {
        run("pauseAudio();")
        DispatchQueue.main.async { [weak self] in self?.currentVideoId = nil }
    }

    private func run(_ js: String) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

extension EmbedStreamPlayer: WKScriptMessageHandler, WKNavigationDelegate {
    public func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any], let event = dict["event"] as? String else { return }
        switch event {
        case "ready":
            DispatchQueue.main.async { self.isReady = true }
        case "stateChange":
            if let state = dict["state"] as? Int {
                switch state {
                case 1:
                    isPlayingHandler?(true)
                case 2, 0:
                    isPlayingHandler?(false)
                    if state == 0 { endHandler?() }
                default:
                    break
                }
            }
        case "timeUpdate":
            timeUpdateHandler?(dict["current"] as? Double ?? 0, dict["duration"] as? Double ?? 0)
        case "error":
            let code = dict["code"] as? Int ?? -1
            errorHandler?(Self.message(forPlayerError: code))
        case "fatal":
            errorHandler?(dict["message"] as? String ?? "The YouTube player failed to load.")
        default:
            break
        }
    }

    private static func message(forPlayerError code: Int) -> String {
        switch code {
        case 2:   return "YouTube rejected the video ID (player error 2)."
        case 5:   return "The YouTube player could not decode this video (player error 5)."
        case 100: return "This video does not exist or is private (player error 100)."
        case 101, 150: return "The uploader disabled embedding for this video (player error \(code)). Download it instead."
        case 153: return "YouTube refused the embedded player request (player error 153). Download the track instead."
        default:  return "YouTube player error \(code)."
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        errorHandler?("Player load failed: \(error.localizedDescription)")
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        errorHandler?("Player load failed: \(error.localizedDescription)")
    }
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        errorHandler?("The YouTube player stopped unexpectedly. Tap play to retry.")
    }
}
