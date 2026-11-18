import Foundation
import Combine

// MARK: - GBK/Big5 等中文编码扩展
extension String.Encoding {
    static let gbk: String.Encoding = {
        let cfEnc = CFStringEncodings.GB_18030_2000
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        return String.Encoding(rawValue: nsEnc)
    }()
    static let big5: String.Encoding = {
        let cfEnc = CFStringEncodings.big5
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        return String.Encoding(rawValue: nsEnc)
    }()
    static let gb2312: String.Encoding = {
        let cfEnc = CFStringEncodings.GB_2312_80
        let nsEnc = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cfEnc.rawValue))
        return String.Encoding(rawValue: nsEnc)
    }()
}

// MARK: - 通用福利平台服务协议
protocol FuliPlatformService: ObservableObject {
    /// 平台唯一名称（与 WelfareSettingsView 中配置一致）
    var platformName: String { get }
    /// 平台唯一 key（用于历史记录定位、路由分发等）
    var platformKey: String { get }
    /// 默认域名列表
    var defaultHosts: [String] { get }
    /// 当前选中的可用域名
    var currentHost: String { get set }
    /// 域名是否已就绪
    var isHostReady: Bool { get set }

    /// 通用 HTTP headers
    func defaultHeaders(host: String) -> [String: String]

    /// 解析首页分类 + 推荐视频
    func fetchHomeContent() async -> FuliHomeResult
    /// 解析分类/子分类视频列表
    func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult
    /// 解析视频详情（含剧集）
    func fetchDetail(vodId: String) async -> FuliDetail
    /// 搜索
    func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult
    /// 获取播放地址（默认直接返回剧集 URL）
    func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult

    /// 内容类型（决定列表点击后进入视频播放还是漫画浏览）
    var contentCategory: FuliContentCategory { get }
    /// 封面图防盗链 Referer。默认 nil，只有需要的远程源注入。
    var imageReferer: String? { get }
    /// 封面图是否需要 SSL 绕过。默认 false，只有需要的远程源启用。
    var imageSSLBypass: Bool { get }

    /// 域名管理
    func reprobe()
    func resetDomain()
}

// MARK: - 内容类型默认实现
extension FuliPlatformService {
    var contentCategory: FuliContentCategory { .video }
    var imageReferer: String? { nil }
    var imageSSLBypass: Bool { false }
    var platformKey: String { "" }
}

// MARK: - 默认实现（域名探测 + HTTP 工具）
extension FuliPlatformService {

    var allHosts: [String] {
        let customs = WelfareDomainStore.shared.domains(for: platformName)
        return customs + defaultHosts
    }

    /// 检查当前平台是否启用了代理
    var isProxyEnabled: Bool {
        WelfareProxyStore.shared.isProxyEnabled(for: platformName)
    }

    /// 对 URL 应用代理（如果启用）
    func applyProxyIfNeeded(_ urlString: String) -> String {
        WelfareProxyStore.shared.proxiedURL(urlString, for: platformName)
    }

    func defaultHeaders(host: String) -> [String: String] {
        [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8",
            "Accept-Language": "zh-CN,zh;q=0.9",
            "Connection": "keep-alive",
            "Cache-Control": "no-cache",
            "Origin": host,
            "Referer": "\(host)/"
        ]
    }

    var session: URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    func reprobe() {
        guard let obj = self as? FuliBaseService else { return }
        obj.currentHost = ""
        obj.isHostReady = false
        Task { _ = await probeHost() }
    }

    func resetDomain() {
        WelfareDomainStore.shared.clearDomains(for: platformName)
        reprobe()
    }

    @discardableResult
    func probeHost() async -> String {
        let proxyEnabled = WelfareProxyStore.shared.isProxyEnabled(for: platformName)
        let hosts = allHosts
        // ✅ 并行探测：原实现是「串行逐个探测 + 单 host 15s 超时」，
        // 当平台前几个 host 全部不可达时（真机实测 173 个 host 里 126 个不可达、
        // 117 个福利平台中 74 个全军覆没），需等 N×15 秒才轮到一个可用的，
        // 表现为播放界面一直卡在「正在解析播放地址」。
        // 改为并行后最坏耗时 = 单个 host 的超时，与 host 数量无关。
        // 语义保持不变：仍取「原始顺序里最靠前」的可用 host。
        let hits: [(index: Int, host: String)] = await withTaskGroup(of: (Int, String)?.self) { group in
            for (index, host) in hosts.enumerated() {
                group.addTask { [weak self] in
                    guard let self = self else { return nil }
                    let urlString = proxyEnabled ? WelfareProxyStore.shared.buildProxiedURL(host) : host
                    guard let url = URL(string: urlString) else { return nil }
                    var req = URLRequest(url: url)
                    // 单 host 超时收紧到 5s：并行下总耗时由最慢的那个决定
                    req.timeoutInterval = 5
                    self.defaultHeaders(host: host).forEach { req.setValue($1, forHTTPHeaderField: $0) }
                    do {
                        let (_, resp) = try await self.session.data(for: req)
                        guard let http = resp as? HTTPURLResponse,
                              (200...299).contains(http.statusCode) else { return nil }
                        return (index, host)
                    } catch {
                        print("[\(platformName)] 探测失败 \(host)\(proxyEnabled ? " (代理)" : ""): \(error.localizedDescription)")
                        return nil
                    }
                }
            }
            var results: [(Int, String)] = []
            for await r in group {
                if let r { results.append(r) }
            }
            return results
        }
        if hits.isEmpty {
            print("[\(platformName)] 并行探测完成：\(hosts.count) 个 host 全部不可用")
        }
        if let best = hits.min(by: { $0.index < $1.index }) {
            let host = best.host
            if let obj = self as? FuliBaseService {
                await MainActor.run {
                    obj.currentHost = host
                    obj.isHostReady = true
                }
            }
            print("[\(platformName)] 选用站点: \(host)\(proxyEnabled ? " (代理)" : "")（并行探测命中 \(hits.count)/\(hosts.count)）")
            return host
        }
        let fallback = hosts.first ?? defaultHosts.first ?? ""
        if let obj = self as? FuliBaseService {
            await MainActor.run {
                obj.currentHost = fallback
                obj.isHostReady = false
            }
        }
        print("[\(platformName)] 所有域名探测失败，保持未就绪状态以便下次重新探测")
        return fallback
    }

    func fetchHTML(_ path: String) async throws -> String {
        let urlStr: String
        if path.hasPrefix("http") {
            urlStr = applyProxyIfNeeded(path)
        } else {
            urlStr = applyProxyIfNeeded(currentHost + (path.hasPrefix("/") ? path : "/\(path)"))
        }
        guard let url = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        defaultHeaders(host: currentHost).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw URLError(.cannotParseResponse)
        }
        return html
    }

    func fetchData(_ urlString: String) async throws -> Data {
        let proxiedURL = applyProxyIfNeeded(urlString)
        guard let url = URL(string: proxiedURL) else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        defaultHeaders(host: currentHost).forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        let direct = episode.url.contains(".m3u8") || episode.url.contains(".mp4") || episode.url.contains(".ts")
        return FuliPlayerResult(url: episode.url, headers: defaultHeaders(host: currentHost), parse: direct ? 0 : 1)
    }

    func ensureHostReady() async {
        if currentHost.isEmpty || !isHostReady {
            _ = await probeHost()
        }
    }
}

// MARK: - 基类（用于 @Published 状态管理）
class FuliBaseService: ObservableObject, FuliPlatformService {
    let platformName: String
    let platformKey: String
    let defaultHosts: [String]

    @Published var currentHost: String = ""
    @Published var isHostReady: Bool = false

    /// 内容类型默认视频；漫画子类 override
    var contentCategory: FuliContentCategory { .video }
    /// 默认不注入图片 Referer；远程配置类服务可 override。
    var imageReferer: String? { nil }
    /// 默认不绕过图片 SSL；远程配置类服务可 override。
    var imageSSLBypass: Bool { false }

    init(platformName: String, defaultHosts: [String], platformKey: String = "") {
        self.platformName = platformName
        self.defaultHosts = defaultHosts
        self.platformKey = platformKey
    }

    func fetchHomeContent() async -> FuliHomeResult { .empty }
    func fetchCategoryContent(category: FuliCategory, subCategory: FuliCategory?, page: Int) async -> FuliCategoryResult {
        FuliCategoryResult(videos: [], page: page, hasMore: false)
    }
    func fetchDetail(vodId: String) async -> FuliDetail {
        FuliDetail(vodId: vodId, vodName: "", vodPic: "", vodContent: nil, playFrom: platformName, episodes: [])
    }
    func fetchSearch(keyword: String, page: Int) async -> FuliSearchResult {
        FuliSearchResult(videos: [], page: page, hasMore: false)
    }

    func fetchPlayerURL(episode: FuliEpisode) async -> FuliPlayerResult {
        let direct = episode.url.contains(".m3u8") || episode.url.contains(".mp4") || episode.url.contains(".ts")
        return FuliPlayerResult(url: episode.url, headers: defaultHeaders(host: currentHost), parse: direct ? 0 : 1)
    }
}
