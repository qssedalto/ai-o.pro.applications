import XCTest
@testable import MallCore

final class MallCoreTests: XCTestCase {
    func testCanonical() {
        XCTAssertEqual(FormSigner.canonical(["sign":"ignore", "race":"规格 A:测试", "num":"1", "empty":"", "card_id":"0", "app_id":"123"], key:"demo"), "app_id=123&card_id=0&num=1&race=规格 A:测试&key=demo")
        XCTAssertEqual(FormSigner.encode("a+b 空~"), "a%2Bb+%E7%A9%BA%7E")
        XCTAssertEqual(FormSigner.signature(["app_id":"123"], key:"demo").count, 32)
    }
    func testCatalog() throws {
        let input: [[String: Any]] = [["name":"测试", "children":[["code":"ABC", "name":"测试商品", "price":12, "stock":"4"]]]]
        let items = try Product.catalog(input)
        XCTAssertEqual(items.first?.price, "12")
        XCTAssertEqual(items.first?.stock, "4")
        XCTAssertEqual(items.first?.id, "ABC")
    }
    func testProductPresentation() throws {
        let data: [[String: Any]] = [["name":"分类","children":[["code":"ONE","name":"商品","stock":10,"delivery_way":0,"cover":"https://imgurloss.xqd.cn/test.png"],["code":"TWO","name":"商品2","cover":"http://example.com/a.png"]]]]
        let items = try Product.catalog(data)
        XCTAssertEqual(items.first?.deliveryWay, 0)
        XCTAssertEqual(items.first?.cover?.host, "imgurloss.xqd.cn")
        XCTAssertNil(items.last?.cover)
    }
    func testVariants() {
        XCTAssertEqual(variants("[category]\nA=1.25\n[category_factory]\nA=1").first?.price, "1.25")
        XCTAssertEqual(variants(["category":["A":"1.25"]]).first?.race, "A")
        XCTAssertTrue(variants([]).isEmpty)
    }
}
