import Foundation

/// Synthetic OGC documents for the OGC tests (M10): a WFS 2.0.0 that pages, its schema, a WMS
/// in both common versions, a WMTS with a Web Mercator matrix set, and an exception report.
enum OGCFixtures {
    static let wfs200 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <wfs:WFS_Capabilities xmlns:wfs="http://www.opengis.net/wfs/2.0" xmlns:ows="http://www.opengis.net/ows/1.1" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:ms="http://mapserver.gis.umn.edu/mapserver" version="2.0.0">
      <ows:ServiceIdentification><ows:Title>Planning WFS</ows:Title><ows:Abstract>Live planning layers.</ows:Abstract><ows:ServiceType>WFS</ows:ServiceType><ows:ServiceTypeVersion>2.0.0</ows:ServiceTypeVersion></ows:ServiceIdentification>
      <ows:OperationsMetadata>
        <ows:Operation name="GetCapabilities"><ows:DCP><ows:HTTP><ows:Get xlink:href="https://planning.example.gov.uk/maps/LIVE/MapServer?map=pa&amp;"/></ows:HTTP></ows:DCP></ows:Operation>
        <ows:Operation name="DescribeFeatureType"/>
        <ows:Operation name="GetFeature">
          <ows:Parameter name="outputFormat"><ows:AllowedValues><ows:Value>application/gml+xml; version=3.2</ows:Value><ows:Value>text/xml; subtype=gml/3.2.1</ows:Value><ows:Value>application/json</ows:Value></ows:AllowedValues></ows:Parameter>
        </ows:Operation>
        <ows:Constraint name="ImplementsResultPaging"><ows:NoValues/><ows:DefaultValue>TRUE</ows:DefaultValue></ows:Constraint>
        <ows:Constraint name="CountDefault"><ows:NoValues/><ows:DefaultValue>2</ows:DefaultValue></ows:Constraint>
      </ows:OperationsMetadata>
      <wfs:FeatureTypeList>
        <wfs:FeatureType>
          <wfs:Name>ms:towns</wfs:Name><wfs:Title>Towns</wfs:Title><wfs:Abstract>Every town.</wfs:Abstract>
          <ows:Keywords><ows:Keyword>towns</ows:Keyword><ows:Keyword>places</ows:Keyword></ows:Keywords>
          <wfs:DefaultCRS>urn:ogc:def:crs:EPSG::27700</wfs:DefaultCRS><wfs:OtherCRS>urn:ogc:def:crs:EPSG::4326</wfs:OtherCRS><wfs:OtherCRS>urn:ogc:def:crs:EPSG::3857</wfs:OtherCRS>
          <ows:WGS84BoundingBox><ows:LowerCorner>-3.5 50.2</ows:LowerCorner><ows:UpperCorner>-2.0 51.0</ows:UpperCorner></ows:WGS84BoundingBox>
        </wfs:FeatureType>
        <wfs:FeatureType>
          <wfs:Name>ms:notes</wfs:Name><wfs:Title>Notes</wfs:Title>
          <wfs:DefaultCRS>urn:ogc:def:crs:EPSG::27700</wfs:DefaultCRS>
          <ows:WGS84BoundingBox><ows:LowerCorner>-3.5 50.2</ows:LowerCorner><ows:UpperCorner>-2.0 51.0</ows:UpperCorner></ows:WGS84BoundingBox>
        </wfs:FeatureType>
      </wfs:FeatureTypeList>
    </wfs:WFS_Capabilities>
    """

    /// A WFS 1.0.0 that offers GML only and cannot page or count.
    static let wfs100 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <WFS_Capabilities version="1.0.0" xmlns="http://www.opengis.net/wfs" xmlns:ms="http://mapserver.gis.umn.edu/mapserver">
      <Service><Name>MapServer WFS</Name><Title>Old planning WFS</Title></Service>
      <Capability><Request>
        <GetCapabilities/><DescribeFeatureType/>
        <GetFeature><ResultFormat><GML2/><GML3/></ResultFormat></GetFeature>
      </Request></Capability>
      <FeatureTypeList>
        <FeatureType><Name>ms:towns</Name><Title>Towns</Title><SRS>EPSG:27700</SRS><LatLongBoundingBox minx="-3.5" miny="50.2" maxx="-2.0" maxy="51.0"/></FeatureType>
      </FeatureTypeList>
    </WFS_Capabilities>
    """

    static let describeTowns = """
    <?xml version="1.0" encoding="UTF-8"?>
    <schema xmlns="http://www.w3.org/2001/XMLSchema" xmlns:ms="http://mapserver.gis.umn.edu/mapserver" xmlns:gml="http://www.opengis.net/gml/3.2" targetNamespace="http://mapserver.gis.umn.edu/mapserver" elementFormDefault="qualified" version="0.1">
      <import namespace="http://www.opengis.net/gml/3.2" schemaLocation="http://schemas.opengis.net/gml/3.2.1/gml.xsd"/>
      <element name="towns" type="ms:townsType" substitutionGroup="gml:AbstractFeature"/>
      <complexType name="townsType"><complexContent><extension base="gml:AbstractFeatureType"><sequence>
        <element name="msGeometry" type="gml:PointPropertyType" minOccurs="0" maxOccurs="1"/>
        <element name="OBJECTID" minOccurs="0" type="int"/>
        <element name="NAME" minOccurs="0" type="string"/>
        <element name="POP" minOccurs="0" type="int"/>
        <element name="WHEN" minOccurs="0" type="dateTime"/>
      </sequence></extension></complexContent></complexType>
      <element name="notes" type="ms:notesType" substitutionGroup="gml:AbstractFeature"/>
      <complexType name="notesType"><complexContent><extension base="gml:AbstractFeatureType"><sequence>
        <element name="NOTE" minOccurs="0" type="string"/>
      </sequence></extension></complexContent></complexType>
    </schema>
    """

    static let wms130 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <WMS_Capabilities version="1.3.0" xmlns="http://www.opengis.net/wms" xmlns:xlink="http://www.w3.org/1999/xlink">
      <Service><Name>WMS</Name><Title>Planning WMS</Title><Abstract>Drawn planning layers.</Abstract><MaxWidth>2048</MaxWidth><MaxHeight>2048</MaxHeight></Service>
      <Capability>
        <Request>
          <GetCapabilities><Format>text/xml</Format></GetCapabilities>
          <GetMap><Format>image/png</Format><Format>image/jpeg</Format><Format>image/geotiff</Format></GetMap>
          <GetFeatureInfo><Format>text/plain</Format></GetFeatureInfo>
        </Request>
        <Layer>
          <Title>Planning</Title>
          <CRS>EPSG:27700</CRS><CRS>EPSG:4326</CRS><CRS>EPSG:3857</CRS>
          <EX_GeographicBoundingBox><westBoundLongitude>-3.5</westBoundLongitude><eastBoundLongitude>-2.0</eastBoundLongitude><southBoundLatitude>50.2</southBoundLatitude><northBoundLatitude>51.0</northBoundLatitude></EX_GeographicBoundingBox>
          <Layer queryable="1"><Name>towns</Name><Title>Towns</Title><Abstract>Every town, drawn.</Abstract><KeywordList><Keyword>towns</Keyword></KeywordList><Style><Name>default</Name><Title>Default</Title></Style></Layer>
          <Layer queryable="0"><Name>roads</Name><Title>Roads</Title><CRS>EPSG:27700</CRS>
            <EX_GeographicBoundingBox><westBoundLongitude>-3.0</westBoundLongitude><eastBoundLongitude>-2.5</eastBoundLongitude><southBoundLatitude>50.5</southBoundLatitude><northBoundLatitude>50.8</northBoundLatitude></EX_GeographicBoundingBox>
          </Layer>
        </Layer>
      </Capability>
    </WMS_Capabilities>
    """

    static let wms111 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE WMT_MS_Capabilities SYSTEM "http://schemas.opengis.net/wms/1.1.1/WMS_MS_Capabilities.dtd">
    <WMT_MS_Capabilities version="1.1.1">
      <Service><Name>OGC:WMS</Name><Title>Old planning WMS</Title></Service>
      <Capability>
        <Request><GetCapabilities><Format>application/vnd.ogc.wms_xml</Format></GetCapabilities><GetMap><Format>image/png</Format></GetMap></Request>
        <Layer>
          <Title>Planning</Title>
          <SRS>EPSG:27700 EPSG:4326</SRS>
          <LatLonBoundingBox minx="-3.5" miny="50.2" maxx="-2.0" maxy="51.0"/>
          <Layer queryable="1"><Name>towns</Name><Title>Towns</Title></Layer>
        </Layer>
      </Capability>
    </WMT_MS_Capabilities>
    """

    static let wmts100 = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Capabilities xmlns="http://www.opengis.net/wmts/1.0" xmlns:ows="http://www.opengis.net/ows/1.1" xmlns:xlink="http://www.w3.org/1999/xlink" version="1.0.0">
      <ows:ServiceIdentification><ows:Title>Planning tiles</ows:Title></ows:ServiceIdentification>
      <ows:OperationsMetadata><ows:Operation name="GetCapabilities"/><ows:Operation name="GetTile"/></ows:OperationsMetadata>
      <Contents>
        <Layer>
          <ows:Title>Basemap</ows:Title><ows:Identifier>basemap</ows:Identifier>
          <ows:WGS84BoundingBox><ows:LowerCorner>-3.5 50.2</ows:LowerCorner><ows:UpperCorner>-2.0 51.0</ows:UpperCorner></ows:WGS84BoundingBox>
          <Style isDefault="true"><ows:Identifier>default</ows:Identifier></Style>
          <Format>image/png</Format>
          <TileMatrixSetLink><TileMatrixSet>webmercator</TileMatrixSet></TileMatrixSetLink>
          <ResourceURL format="image/png" resourceType="tile" template="https://tiles.example.gov.uk/wmts/basemap/{Style}/{TileMatrixSet}/{TileMatrix}/{TileRow}/{TileCol}.png"/>
        </Layer>
        <TileMatrixSet>
          <ows:Identifier>webmercator</ows:Identifier><ows:SupportedCRS>urn:ogc:def:crs:EPSG::3857</ows:SupportedCRS>
          <TileMatrix><ows:Identifier>0</ows:Identifier><ScaleDenominator>559082264.0287178</ScaleDenominator><TopLeftCorner>-20037508.3427892 20037508.3427892</TopLeftCorner><TileWidth>256</TileWidth><TileHeight>256</TileHeight><MatrixWidth>1</MatrixWidth><MatrixHeight>1</MatrixHeight></TileMatrix>
          <TileMatrix><ows:Identifier>1</ows:Identifier><ScaleDenominator>279541132.0143589</ScaleDenominator><TopLeftCorner>-20037508.3427892 20037508.3427892</TopLeftCorner><TileWidth>256</TileWidth><TileHeight>256</TileHeight><MatrixWidth>2</MatrixWidth><MatrixHeight>2</MatrixHeight></TileMatrix>
        </TileMatrixSet>
        <TileMatrixSet>
          <ows:Identifier>bng</ows:Identifier><ows:SupportedCRS>urn:ogc:def:crs:EPSG::27700</ows:SupportedCRS>
          <TileMatrix><ows:Identifier>EPSG:27700:0</ows:Identifier><ScaleDenominator>1</ScaleDenominator><TopLeftCorner>0 0</TopLeftCorner><TileWidth>256</TileWidth><TileHeight>256</TileHeight><MatrixWidth>1</MatrixWidth><MatrixHeight>1</MatrixHeight></TileMatrix>
          <TileMatrix><ows:Identifier>EPSG:27700:1</ows:Identifier><ScaleDenominator>1</ScaleDenominator><TopLeftCorner>0 0</TopLeftCorner><TileWidth>256</TileWidth><TileHeight>256</TileHeight><MatrixWidth>2</MatrixWidth><MatrixHeight>2</MatrixHeight></TileMatrix>
        </TileMatrixSet>
      </Contents>
    </Capabilities>
    """

    static let exceptionReport = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ows:ExceptionReport xmlns:ows="http://www.opengis.net/ows/1.1" version="2.0.0"><ows:Exception exceptionCode="InvalidParameterValue" locator="service"><ows:ExceptionText>WMTS is not enabled on this endpoint</ows:ExceptionText></ows:Exception></ows:ExceptionReport>
    """

    static let towns: [(id: Int, name: String, pop: Int, x: Double, y: Double)] = [
        (1, "Town 1", 250, 250000, 60000), (2, "Town 2", 500, 251000, 61000), (3, "Town 3", 750, 252000, 62000),
        (4, "Town 4", 1000, 253000, 63000), (5, "Town 5", 1250, 254000, 64000),
    ]

    /// `resultType=hits`, WFS 2.0 style.
    static let hits = """
    <?xml version="1.0" encoding="UTF-8"?>
    <wfs:FeatureCollection xmlns:wfs="http://www.opengis.net/wfs/2.0" numberMatched="5" numberReturned="0" timeStamp="2026-09-17T20:00:00"/>
    """

    /// A GeoJSON page of towns `range`, as a GeoJSON-capable WFS writes it (WGS 84 when asked, else native).
    static func geoJSONPage(_ range: Range<Int>, wgs84: Bool) -> String {
        let features = towns[range.clamped(to: towns.indices)].map { t -> String in
            let coords = wgs84 ? "[\(-3.5 + Double(t.id) * 0.1),\(50.2 + Double(t.id) * 0.1)]" : "[\(t.x),\(t.y)]"
            return #"{"type":"Feature","id":"towns.\#(t.id)","properties":{"OBJECTID":\#(t.id),"NAME":"\#(t.name)","POP":\#(t.pop),"WHEN":"2026-06-0\#(t.id)T10:00:00Z"},"geometry":{"type":"Point","coordinates":\#(coords)}}"#
        }
        let crs = wgs84 ? "" : #","crs":{"type":"name","properties":{"name":"urn:ogc:def:crs:EPSG::27700"}}"#
        return #"{"type":"FeatureCollection","numberMatched":5,"numberReturned":\#(features.count)\#(crs),"features":[\#(features.joined(separator: ","))]}"#
    }

    /// A GML 3.2 page of towns `range` in British National Grid.
    static func gmlPage(_ range: Range<Int>) -> String {
        let members = towns[range.clamped(to: towns.indices)].map { t in """
              <wfs:member>
                <ms:towns gml:id="towns.\(t.id)">
                  <ms:msGeometry><gml:Point srsName="urn:ogc:def:crs:EPSG::27700" gml:id="towns.\(t.id).g"><gml:pos>\(t.x) \(t.y)</gml:pos></gml:Point></ms:msGeometry>
                  <ms:OBJECTID>\(t.id)</ms:OBJECTID><ms:NAME>\(t.name)</ms:NAME><ms:POP>\(t.pop)</ms:POP>
                </ms:towns>
              </wfs:member>
            """ }.joined(separator: "\n")
        return """
            <?xml version="1.0" encoding="UTF-8"?>
            <wfs:FeatureCollection xmlns:wfs="http://www.opengis.net/wfs/2.0" xmlns:gml="http://www.opengis.net/gml/3.2" xmlns:ms="http://mapserver.gis.umn.edu/mapserver" numberMatched="5" numberReturned="\(range.count)" timeStamp="2026-09-17T20:00:00">
            \(members)
            </wfs:FeatureCollection>
            """
    }

    /// The smallest valid PNG: one transparent pixel.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==")!
}
