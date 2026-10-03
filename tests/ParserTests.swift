import Foundation

@main struct ParserTests {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() throws {
        let base = URL(string:"https://example.test/catalog/list.m3u")!
        let list = """
        #EXTM3U
        #EXTINF:-1 tvg-id="one" tvg-logo="https://example.test/a.png" group-title="News, World",Channel One
        ../live/1.m3u8
        #EXTINF:-1,Duplicate
        ../live/1.m3u8
        #EXTINF:-1 type="movie" group-title="Movies",A Movie
        https://example.test/movie/2.mp4
        #EXTINF:-1 group-title="Drama",Example Series S01E02
        https://example.test/series/3.mp4
        #EXTINF:-1,Unsafe
        javascript:alert(1)
        """
        let items = try HubM3U.parse(Data(("\u{feff}" + list).utf8),provider:"p",base:base)
        check(items.count == 4,"Deduplication, grouping or scheme filtering failed")
        check(items[0].category == "News, World","Quoted comma was lost")
        check(items[0].url == "https://example.test/live/1.m3u8","Relative URL resolution failed")
        check(items[1].kind == .movie,"Movie classification failed")
        check(items[2].kind == .series && items[3].parent == items[2].id,"Series hierarchy failed")
        check(items[3].season == 1 && items[3].episode == 2,"Episode metadata failed")
        var large = "#EXTM3U\n"
        for i in 0..<20_000 { large += "#EXTINF:-1 tvg-id=\"\(i)\",Channel \(i)\nhttps://example.test/\(i).m3u8\n" }
        let start = Date(); let parsed = try HubM3U.parse(Data(large.utf8),provider:"large",base:base)
        check(parsed.count == 20_000,"Large playlist import lost entries")
        print("20,000 channel fixture parsed in \(Date().timeIntervalSince(start)) seconds")
        let hls = Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts".utf8)
        check(try HubM3U.parse(hls,provider:"p",base:base).count == 1,"HLS segments became channels")
        do { _ = try HubM3U.parse(Data("<html>error</html>".utf8),provider:"p",base:base); fatalError("Invalid feed accepted") } catch is HubFailure {}
        do { _ = try hubWebURL("file:///tmp/passwords"); fatalError("Local scheme accepted") } catch is HubFailure {}
        let xml = """
        <?xml version="1.0"?><tv><programme channel="one" start="20990101000000 +0000" stop="20990101010000 +0000"><title>News &amp; Weather</title></programme></tv>
        """
        let programmes = try HubXMLTV.parse(Data(xml.utf8))
        check(programmes.count == 1 && programmes[0].title == "News & Weather","XMLTV title decoding failed")
        check(programmes[0].end - programmes[0].start == 3600,"XMLTV timestamp failed")
        print("All parser fixtures passed.")
    }
}
