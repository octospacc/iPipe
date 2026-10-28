import Foundation
import WebKit
import Combine

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// EmbedStreamPlayer hosts an invisible/background WKWebView configured to play YouTube embed streams.
/// This uses the official YouTube IFrame Player API (`www.youtube.com/embed/{id}`) directly,
/// allowing 100% legal, non-fragile, zero-API-key playback without needing external scrapers or failing proxies.
public final class EmbedStreamPlayer: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = EmbedStreamPlayer()
    
    @Published public private(set) var isReady: Bool = false
    @Published public private(set) var currentVideoId: String? = nil
    
    private var webView: WKWebView?
    private var isPlayingHandler: ((Bool) -> Void)?
    private var timeUpdateHandler: ((Double, Double) -> Void)?
    private var endHandler: (() -> Void)?
    
    private override init() {
        super.init()
        setupWebView()
    }
    
    private func setupWebView() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let config = WKWebViewConfiguration()
            #if os(iOS)
            config.allowsInlineMediaPlayback = true
            config.allowsPictureInPictureMediaPlayback = true
            #endif
            config.mediaTypesRequiringUserActionForPlayback = []
            
            let userContentController = WKUserContentController()
            userContentController.add(self, name: "playerCallback")
            config.userContentController = userContentController
            
            let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 200), configuration: config)
            wv.navigationDelegate = self
            
            #if os(iOS)
            wv.isOpaque = false
            wv.backgroundColor = .clear
            #endif
            
            self.webView = wv
            self.loadPlayerHTML()
        }
    }
    
    private func loadPlayerHTML() {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body, html { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
                #player { width: 100%; height: 100%; }
            </style>
        </head>
        <body>
            <div id="player"></div>
            <script>
                var tag = document.createElement('script');
                tag.src = "https://www.youtube.com/iframe_api";
                var firstScriptTag = document.getElementsByTagName('script')[0];
                firstScriptTag.parentNode.insertBefore(tag, firstScriptTag);

                var player;
                function onYouTubeIframeAPIReady() {
                    window.webkit.messageHandlers.playerCallback.postMessage({ event: 'ready' });
                }

                function loadAndPlay(videoId) {
                    if (player) {
                        player.loadVideoById(videoId);
                        player.playVideo();
                    } else {
                        player = new YT.Player('player', {
                            height: '100%',
                            width: '100%',
                            videoId: videoId,
                            playerVars: {
                                'playsinline': 1,
                                'controls': 0,
                                'autoplay': 1,
                                'rel': 0,
                                'origin': 'https://www.youtube.com'
                            },
                            events: {
                                'onReady': onPlayerReady,
                                'onStateChange': onPlayerStateChange
                            }
                        });
                    }
                }

                function onPlayerReady(event) {
                    event.target.playVideo();
                    startTimeTracker();
                }

                function onPlayerStateChange(event) {
                    // YT.PlayerState: ENDED = 0, PLAYING = 1, PAUSED = 2, BUFFERING = 3
                    window.webkit.messageHandlers.playerCallback.postMessage({
                        event: 'stateChange',
                        state: event.data
                    });
                }

                function startTimeTracker() {
                    setInterval(function() {
                        if (player && player.getCurrentTime) {
                            var current = player.getCurrentTime();
                            var duration = player.getDuration();
                            window.webkit.messageHandlers.playerCallback.postMessage({
                                event: 'timeUpdate',
                                current: current,
                                duration: duration
                            });
                        }
                    }, 500);
                }

                function playAudio() {
                    if (player && player.playVideo) player.playVideo();
                }

                function pauseAudio() {
                    if (player && player.pauseVideo) player.pauseVideo();
                }

                function seekAudio(seconds) {
                    if (player && player.seekTo) player.seekTo(seconds, true);
                }
            </script>
        </body>
        </html>
        """
        webView?.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
    }
    
    public func setCallbacks(
        onPlayingChange: @escaping (Bool) -> Void,
        onTimeUpdate: @escaping (Double, Double) -> Void,
        onEnded: @escaping () -> Void
    ) {
        self.isPlayingHandler = onPlayingChange
        self.timeUpdateHandler = onTimeUpdate
        self.endHandler = onEnded
    }
    
    public func playVideo(videoId: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentVideoId = videoId
            let js = "loadAndPlay('\(videoId)');"
            self.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }
    
    public func play() {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("playAudio();", completionHandler: nil)
        }
    }
    
    public func pause() {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("pauseAudio();", completionHandler: nil)
        }
    }
    
    public func seek(to seconds: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("seekAudio(\(seconds));", completionHandler: nil)
        }
    }
    
    public func stop() {
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript("pauseAudio();", completionHandler: nil)
            self?.currentVideoId = nil
        }
    }
}

extension EmbedStreamPlayer: WKScriptMessageHandler, WKNavigationDelegate {
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dict = message.body as? [String: Any],
              let event = dict["event"] as? String else {
            return
        }
        
        switch event {
        case "ready":
            self.isReady = true
        case "stateChange":
            if let state = dict["state"] as? Int {
                // 1 = PLAYING, 2 = PAUSED, 0 = ENDED
                if state == 1 {
                    self.isPlayingHandler?(true)
                } else if state == 2 {
                    self.isPlayingHandler?(false)
                } else if state == 0 {
                    self.isPlayingHandler?(false)
                    self.endHandler?()
                }
            }
        case "timeUpdate":
            let current = dict["current"] as? Double ?? 0
            let duration = dict["duration"] as? Double ?? 0
            self.timeUpdateHandler?(current, duration)
        default:
            break
        }
    }
}
