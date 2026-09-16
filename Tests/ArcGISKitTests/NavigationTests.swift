import XCTest
import Foundation
import ArcGISKit

final class NavigationTests: XCTestCase {

    private let root = URL(string: "https://gis.example/arcgis/rest/services")!
    private lazy var server = ServerRecord(id: 1, rootURL: root, friendlyName: "Ashcombe",
                                           lastVisitedAt: Date(timeIntervalSince1970: 1_700_000_000))

    private func service(_ id: Int64, _ name: String, _ type: ServiceType, folder: String = "",
                         extent: BoundingBox? = nil, fetched: Bool = false) -> ServiceRecord {
        ServiceRecord(id: id, serverID: 1, folderPath: folder, name: folder.isEmpty ? name : folder + "/" + name,
                      type: type, url: root.appendingPathComponent(folder.isEmpty ? name : folder + "/" + name)
                        .appendingPathComponent(type.name), extentWGS84: extent,
                      fetchedAt: fetched ? Date() : nil)
    }

    func testTreeShapeFoldersFirstThenServicesThenLayers() {
        let box = BoundingBox(minX: -1, minY: 51, maxX: 0, maxY: 52)
        let services = [
            service(1, "Zebra", .mapServer),
            service(2, "Apple", .featureServer, fetched: true),
            service(3, "Apple", .mapServer),
            service(4, "Geometry", .other("GeometryServer"), folder: "Utilities"),
            service(5, "Deep", .mapServer, folder: "Utilities/Nested", extent: box),
            service(6, "Roads", .featureServer, folder: "Transport"),
        ]
        let layers: [Int64: [LayerRecord]] = [
            2: [LayerRecord(id: 20, serviceID: 2, layerID: 0, name: "Points", extractable: true,
                            extentWGS84: BoundingBox(minX: 10, minY: 10, maxX: 11, maxY: 11)),
                LayerRecord(id: 21, serviceID: 2, layerID: 5, name: "Lookup", isTable: true)],
        ]
        let tree = TreeBuilder.build(server: server, services: services, layersByService: layers)

        XCTAssertEqual(tree.id, .server(1))
        XCTAssertEqual(tree.name, "Ashcombe")
        XCTAssertEqual(tree.children.map(\.name), ["Transport", "Utilities", "Apple", "Apple", "Zebra"])
        XCTAssertEqual(tree.children.map(\.kind), [.folder, .folder, .service(.featureServer), .service(.mapServer), .service(.mapServer)])

        let utilities = tree.children[1]
        XCTAssertEqual(utilities.id, .folder(serverID: 1, path: "Utilities"))
        XCTAssertEqual(utilities.children.map(\.name), ["Nested", "Geometry"])
        XCTAssertEqual(utilities.children[0].id, .folder(serverID: 1, path: "Utilities/Nested"))
        XCTAssertEqual(utilities.children[0].folderDepth, 1)
        XCTAssertEqual(utilities.children[0].children[0].folderDepth, 2)
        XCTAssertEqual(utilities.children[0].extent, box, "folder extent is the union of its children")
        XCTAssertEqual(utilities.extent, box)
        XCTAssertFalse(utilities.children[1].isExpandable, "a GeometryServer has no layers")

        let apple = tree.children[2]
        XCTAssertTrue(apple.isExpandable)
        XCTAssertEqual(apple.children.map(\.name), ["Points", "Lookup"])
        XCTAssertEqual(apple.children[0].kind, .layer)
        XCTAssertEqual(apple.children[0].layerID, 0)
        XCTAssertEqual(apple.children[0].extractable, true)
        XCTAssertEqual(apple.children[1].kind, .table)
        XCTAssertEqual(apple.extent, BoundingBox(minX: 10, minY: 10, maxX: 11, maxY: 11),
                       "service without its own extent takes its layers' union")
        XCTAssertEqual(tree.extent, BoundingBox(minX: -1, minY: 10, maxX: 11, maxY: 52))
        XCTAssertTrue(tree.children[4].isExpandable, "an uncrawled MapServer is still expandable")
        XCTAssertEqual(tree.children[4].children, [])

        XCTAssertEqual(tree.find(.layer(21))?.name, "Lookup")
        XCTAssertNil(tree.find(.layer(99)))
    }

    func testPathBarContent() {
        let svc = service(7, "LLPG", .mapServer, folder: "Property")
        let layer = LayerRecord(id: 70, serviceID: 7, layerID: 3, name: "BLPU Addresses")

        let atServer = PathBarContent.build(server: server)
        XCTAssertEqual(atServer.segments.map(\.label), ["Ashcombe"])
        XCTAssertEqual(atServer.tail, "arcgis/rest/services")
        XCTAssertEqual(atServer.url, root)

        let atFolder = PathBarContent.build(server: server, folderPath: "Property/Sub")
        XCTAssertEqual(atFolder.segments.map(\.label), ["Ashcombe", "Property", "Sub"])
        XCTAssertEqual(atFolder.segments[2].id, .folder(serverID: 1, path: "Property/Sub"))
        XCTAssertEqual(atFolder.url.absoluteString, root.absoluteString + "/Property/Sub")

        let atLayer = PathBarContent.build(server: server, service: svc, layer: layer)
        XCTAssertEqual(atLayer.segments.map(\.label), ["Ashcombe", "Property", "LLPG", "MapServer", "3 BLPU Addresses"])
        XCTAssertEqual(atLayer.segments[1].id, .folder(serverID: 1, path: "Property"))
        XCTAssertEqual(atLayer.segments[2].id, .service(7))
        XCTAssertEqual(atLayer.segments[4].id, .layer(70))
        XCTAssertEqual(atLayer.url.absoluteString, root.absoluteString + "/Property/LLPG/MapServer/3")
    }

    func testBoundingBoxHelpers() {
        let a = BoundingBox(minX: 0, minY: 0, maxX: 1, maxY: 1)
        let b = BoundingBox(minX: -2, minY: 0.5, maxX: 0.5, maxY: 3)
        XCTAssertEqual(a.union(b), BoundingBox(minX: -2, minY: 0, maxX: 1, maxY: 3))
        XCTAssertEqual(BoundingBox.union(of: []), nil)
        XCTAssertEqual(BoundingBox.union(of: [a, .world]), a, "a world-sized box is ignored beside real ones")
        XCTAssertEqual(BoundingBox.union(of: [.world]), .world, "but stands alone when it is all there is")
        XCTAssertTrue(BoundingBox.world.isWorldSized)
        XCTAssertFalse(a.isWorldSized)
        XCTAssertEqual(BoundingBox(json: a.json), a)
        XCTAssertNil(BoundingBox(json: "nope"))
        XCTAssertEqual(BoundingBox(minX: -200, minY: -95, maxX: 200, maxY: 95).clampedToWorld, .world)
    }
}
