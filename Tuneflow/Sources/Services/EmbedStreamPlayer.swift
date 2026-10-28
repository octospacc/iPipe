import Foundation
import WebKit
import Combine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Streams via the official YouTube IFrame Player API inside a WKWebView.
/// Fixes: commands issued before the iframe API loaded were silently dropped
/// (now queued until "ready"), and player errors are now reported.
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
            let config = WKWebViewConfiguration()
            #if os(iOS)
            config.allowsInlineMediaPlayback = true
            config.allowsPictureInPictureMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = []
            #else
            config.mediaTypesRequiringUserActionForPlayback = []
            #endif

            let ucc = WKUserContentController()
            ucc.add(self, name: "playerCallback")
            config.userContentController = ucc

            // Must be >= 200x200 or YouTube refuses to play.
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 220, height: 220), configuration: config)
            wv.navigationDelegate = self
            wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

            #if os(iOS)
            wv.isOpaque = false
            wv.backgroundColor = .clear
            // A detached web view gets suspended on iOS; park it (nearly invisible) in the window.
            wv.alpha = 0.01
            wv.isUserInteractionEnabled = false
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            scene?.windows.first?.addSubview(wv)
            #endif

            self.webView = wv
            self.loadPlayerHTML()
        }
    }

    private func loadPlayerHTML() {
        let html = """
        <!DOCTYPE html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>body,html{margin:0;padding:0;width:100%;height:100%;background:#000;overflow:hidden}#player{width:100%;height:100%}</style>
        </head><body><div id="player"></div>
        <script>
        var player = null, apiReady = false, queued = null, tracker = null;
        function post(o){ window.webkit.messageHandlers.playerCallback.postMessage(o); }
        var tag = document.createElement('script');
        tag.src = "https://www.youtube.com/iframe_api";
        document.head.appendChild(tag);

        function onYouTubeIframeAPIReady(){
            apiReady = true;
            post({event:'ready'});
            if (queued) { var v = queued; queued = null; loadAndPlay(v); }
        }
        function loadAndPlay(videoId){
            if (!apiReady) { queued = videoId; return; }
            if (player && player.loadVideoById) { player.loadVideoById(videoId); return; }
            player = new YT.Player('player', {
                height:'100%', width:'100%', videoId: videoId,
                playerVars:{playsinline:1, controls:0, autoplay:1, rel:0, origin:'https://www.youtube.com'},
                events:{ onReady:onPlayerReady, onStateChange:onPlayerStateChange, onError:onPlayerError }
            });
        }
        function onPlayerReady(e){ e.target.playVideo(); startTracker(); }
        function onPlayerStateChange(e){ post({event:'stateChange', state:e.data}); }
        function onPlayerError(e){ post({event:'error', code:e.data}); }
        function startTracker(){
            if (tracker) return;
            tracker = setInterval(function(){
                if (player && player.getCurrentTime)
                    post({event:'timeUpdate', current:player.getCurrentTime(), duration:player.getDuration()});
            }, 500);
        }
        function playAudio(){ if (player && player.playVideo) player.playVideo(); }
        function pauseAudio(){ if (player && player.pauseVideo) player.pauseVideo(); }
        function seekAudio(s){ if (player && player.seekTo) player.seekTo(s, true); }
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
                if state == 1 { isPlayingHandler?(true) }
                else if state == 2 { isPlayingHandler?(false) }
                else if state == 0 { isPlayingHandler?(false); endHandler?() }
            }
        case "timeUpdate":
            timeUpdateHandler?(dict["current"] as? Double ?? 0, dict["duration"] as? Double ?? 0)
        case "error":
            let code = dict["code"] as? Int ?? -1
            errorHandler?("YouTube player error \(code) (101/150 = embedding disabled for this video)")
        default: break
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        errorHandler?("Player load failed: \(error.localizedDescription)")
    }
    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        errorHandler?("Player load failed: \(error.localizedDescription)")
    }
}
