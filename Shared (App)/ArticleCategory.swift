import SwiftUI

enum ArticleCategory: String {
    case news = "News"
    case video = "Video"
    case dev = "Dev"
    case social = "Social"
    case shopping = "Shopping"
    case government = "Govt"

    var color: Color {
        switch self {
        case .news:       return .blue
        case .video:      return .red
        case .dev:        return .purple
        case .social:     return .pink
        case .shopping:   return .green
        case .government: return .indigo
        }
    }

    private static let domains: [String: ArticleCategory] = [
        // US newspapers / wire services
        "nytimes.com": .news, "wsj.com": .news, "washingtonpost.com": .news,
        "usatoday.com": .news, "latimes.com": .news, "chicagotribune.com": .news,
        "nypost.com": .news, "nydailynews.com": .news, "sfchronicle.com": .news,
        "bostonglobe.com": .news, "dallasnews.com": .news, "miamiherald.com": .news,
        "denverpost.com": .news, "seattletimes.com": .news, "startribune.com": .news,
        "inquirer.com": .news, "ajc.com": .news, "statesman.com": .news,
        "reuters.com": .news, "apnews.com": .news, "upi.com": .news,

        // US cable / broadcast / public radio
        "cnn.com": .news, "foxnews.com": .news, "nbcnews.com": .news,
        "abcnews.go.com": .news, "cbsnews.com": .news, "msnbc.com": .news,
        "pbs.org": .news, "npr.org": .news,

        // UK / Ireland
        "theguardian.com": .news, "bbc.com": .news, "bbc.co.uk": .news,
        "thetimes.co.uk": .news, "thetimes.com": .news, "telegraph.co.uk": .news,
        "independent.co.uk": .news, "dailymail.co.uk": .news, "mirror.co.uk": .news,
        "ft.com": .news, "economist.com": .news, "standard.co.uk": .news,
        "metro.co.uk": .news, "news.sky.com": .news, "itv.com": .news,
        "irishtimes.com": .news,

        // International
        "aljazeera.com": .news, "dw.com": .news, "france24.com": .news,
        "lemonde.fr": .news, "spiegel.de": .news, "scmp.com": .news,
        "japantimes.co.jp": .news, "straitstimes.com": .news,
        "smh.com.au": .news, "theage.com.au": .news, "abc.net.au": .news,
        "cbc.ca": .news, "globalnews.ca": .news, "theglobeandmail.com": .news,
        "nationalpost.com": .news,

        // Politics
        "politico.com": .news, "axios.com": .news, "thehill.com": .news,
        "realclearpolitics.com": .news,

        // Business / finance
        "bloomberg.com": .news, "cnbc.com": .news, "marketwatch.com": .news,
        "forbes.com": .news, "fortune.com": .news, "businessinsider.com": .news,
        "barrons.com": .news, "fastcompany.com": .news, "inc.com": .news,

        // Magazines / long-form / opinion
        "theatlantic.com": .news, "newyorker.com": .news, "vox.com": .news,
        "slate.com": .news, "salon.com": .news, "time.com": .news,
        "newsweek.com": .news, "thedailybeast.com": .news, "harpers.org": .news,
        "vanityfair.com": .news, "gq.com": .news, "esquire.com": .news,
        "rollingstone.com": .news, "motherjones.com": .news, "propublica.org": .news,
        "theintercept.com": .news, "nationalreview.com": .news, "thenation.com": .news,
        "reason.com": .news, "semafor.com": .news, "puck.news": .news,

        // Tech journalism
        "theverge.com": .news, "macrumors.com": .news, "techcrunch.com": .news,
        "arstechnica.com": .news, "engadget.com": .news, "gizmodo.com": .news,
        "mashable.com": .news, "cnet.com": .news, "zdnet.com": .news,
        "wired.com": .news, "9to5mac.com": .news, "9to5google.com": .news,
        "androidcentral.com": .news,

        // Science
        "scientificamerican.com": .news, "nature.com": .news,
        "newscientist.com": .news, "popsci.com": .news, "smithsonianmag.com": .news,

        // Sports
        "espn.com": .news, "si.com": .news, "theathletic.com": .news,
        "bleacherreport.com": .news,

        // Entertainment
        "variety.com": .news, "hollywoodreporter.com": .news, "ew.com": .news,
        "people.com": .news, "eonline.com": .news,

        "youtube.com": .video, "youtu.be": .video, "vimeo.com": .video,
        "twitch.tv": .video,

        "github.com": .dev, "gitlab.com": .dev, "stackoverflow.com": .dev,
        "news.ycombinator.com": .dev, "dev.to": .dev, "medium.com": .dev,
        "arxiv.org": .dev,

        "twitter.com": .social, "x.com": .social, "reddit.com": .social,
        "instagram.com": .social, "threads.net": .social, "facebook.com": .social,
        "linkedin.com": .social,

        "amazon.com": .shopping, "etsy.com": .shopping,
    ]

    // Matches the exact domain or a subdomain of it (e.g. "m.youtube.com",
    // "amp.theguardian.com"), so feed/AMP/mobile variants still tag correctly.
    static func forURL(_ urlString: String) -> ArticleCategory? {
        guard var host = URL(string: urlString)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }

        // Catches every US federal/state/local site (whitehouse.gov, irs.gov,
        // cdc.gov, congress.gov, ...), US military (.mil), and every UK
        // government site (gov.uk, hmrc.gov.uk, ...) without needing to list
        // individual agencies — the TLD/suffix itself is the signal.
        if host == "gov" || host.hasSuffix(".gov")
            || host == "mil" || host.hasSuffix(".mil")
            || host == "gov.uk" || host.hasSuffix(".gov.uk") {
            return .government
        }

        if let direct = domains[host] { return direct }
        for (domain, category) in domains where host.hasSuffix("." + domain) {
            return category
        }
        return nil
    }
}
