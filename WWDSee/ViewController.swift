import UIKit
import CoreLocation
import MapboxGL
import JavaScriptCore
import MBProgressHUD

class ListingAnnotation:  MGLPointAnnotation {}
class StartingAnnotation: MGLPointAnnotation {}
class KeyLine: MGLPolyline {}
class RouteLine: MGLPolyline {}

class ViewController: UIViewController,
                      DrawingViewDelegate,
                      MGLMapViewDelegate {

    var map: MGLMapView!
    var js: JSContext!
    var drawingView: DrawingView!
    var geocoder: MBGeocoder!
    var startingPoint: StartingAnnotation?
    var directions: MBDirections?
    var route: [CLLocationCoordinate2D]?
    var routeLine: RouteLine?

    override func viewDidLoad() {
        super.viewDidLoad()

        title = "Search Listings"

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .Organize,
            target: self,
            action: "swapStyle")

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .Search,
            target: self,
            action: "startSearch")

        map = MGLMapView(frame: view.bounds)
        map.delegate = self
        map.autoresizingMask = .FlexibleWidth | .FlexibleHeight
        map.centerCoordinate = CLLocationCoordinate2D(latitude: 39.74185,
            longitude: -104.981105)
        map.zoomLevel = 10
        view.addSubview(map)

        map.addGestureRecognizer(UILongPressGestureRecognizer(target: self,
            action: "handleLongPress:"))
        map.addGestureRecognizer({
            let doubleLongPress = UILongPressGestureRecognizer(target: self,
                action: "handleDoubleLongPress:")
            doubleLongPress.numberOfTouchesRequired = 2
            return doubleLongPress
            }())

        js = JSContext(virtualMachine: JSVirtualMachine())

        js.exceptionHandler = { context, value in
            NSLog("Exception: %@", value)
        }

        let listingsJS = NSString(contentsOfFile:
            NSBundle.mainBundle().pathForResource("denver", ofType: "geojson")!,
            encoding: NSUTF8StringEncoding,
            error: nil)
        js.setObject(listingsJS, forKeyedSubscript: "listings")
        js.evaluateScript("var listings = JSON.parse(listings)")

        let utilJS = NSString(contentsOfFile:
            NSBundle.mainBundle().pathForResource("javascript.util.min", ofType: "js")!,
            encoding: NSUTF8StringEncoding,
            error: nil) as! String
        js.evaluateScript(utilJS)

        let turfJS = NSString(contentsOfFile:
            NSBundle.mainBundle().pathForResource("turf.min", ofType: "js")!,
            encoding: NSUTF8StringEncoding,
            error: nil) as! String
        js.evaluateScript(turfJS)

        geocoder = MBGeocoder(accessToken: MGLAccountManager.accessToken())
    }

    func swapStyle() {
        if (map.styleURL.absoluteString!.hasSuffix("emerald-v7.json")) {
            map.styleURL = NSURL(string: "asset://styles/mapbox-streets-v7.json")
        } else {
            map.styleURL = NSURL(string: "asset://styles/emerald-v7.json")
        }
    }

    func handleLongPress(longPress: UILongPressGestureRecognizer) {
        if (longPress.state == .Began) {
            let coordinate = map.convertPoint(longPress.locationInView(longPress.view),
                toCoordinateFromView: map)
            if (startingPoint != nil) {
                map.removeAnnotation(startingPoint)
            }
            if (routeLine != nil) {
                map.removeAnnotation(routeLine)
            }
            startingPoint = StartingAnnotation()
            startingPoint?.title = "Starting Location"
            startingPoint?.coordinate = coordinate
            map.addAnnotation(startingPoint)
        }
    }

    func handleDoubleLongPress(longPress: UILongPressGestureRecognizer) {
        if (longPress.state == .Began) {
            map.removeAnnotations(map.annotations)
            if (drawingView != nil) {
                drawingView.removeFromSuperview()
                drawingView = nil
            }
        }
    }

    func startSearch() {
        navigationItem.leftBarButtonItem!.enabled = false

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .Cancel,
            target: self,
            action: "cancelSearch")

        map.userInteractionEnabled = false

        drawingView = DrawingView(frame: view.bounds)
        drawingView.delegate = self
        view.addSubview(drawingView)
    }

    func cancelSearch() {
        navigationItem.leftBarButtonItem!.enabled = true

        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .Search,
            target: self,
            action: "startSearch")

        map.userInteractionEnabled = true

        drawingView.removeFromSuperview()
        drawingView = nil
    }

    func drawingView(drawingView: DrawingView, didDrawWithPoints points: [CGPoint]) {
        var polygon = NSMutableDictionary()

        polygon["type"] = "FeatureCollection"

        var coordinatesArray = NSMutableArray()

        var coordinates = [CLLocationCoordinate2D]()

        for point in points {
            let coordinate = map.convertPoint(point, toCoordinateFromView: map)
            coordinates.append(coordinate)
            coordinatesArray.addObject(
                NSArray(objects: NSNumber(double: coordinate.longitude),
                    NSNumber(double: coordinate.latitude)))
        }

        var geometry = NSMutableDictionary()
        geometry["type"] = "Polygon"
        geometry["coordinates"] = NSArray(object: coordinatesArray)

        var feature = NSMutableDictionary()
        feature["geometry"] = geometry
        feature["type"] = "Feature"
        feature["properties"] = NSDictionary()

        var features = NSArray(object: feature)

        polygon["features"] = features

        let polygonJSON = NSString(data:
            NSJSONSerialization.dataWithJSONObject(polygon,
                options: nil,
                error: nil)!,
            encoding: NSUTF8StringEncoding)

        js.setObject(polygonJSON, forKeyedSubscript: "polygonJSON")
        js.evaluateScript("var polygon = JSON.parse(polygonJSON)")

        js.evaluateScript("var within = turf.within(listings, polygon)")

        var annotations = [MGLAnnotation]()

        for i in 0..<js.evaluateScript("within.features.length").toInt32() {
            js.setObject(NSNumber(int: i), forKeyedSubscript: "i")
            let listing = js.evaluateScript("within.features[i]")
            let lon = listing.objectForKeyedSubscript("geometry").objectForKeyedSubscript("coordinates").objectAtIndexedSubscript(0).toDouble()
            let lat = listing.objectForKeyedSubscript("geometry").objectForKeyedSubscript("coordinates").objectAtIndexedSubscript(1).toDouble()
            let price = "$" + listing.objectForKeyedSubscript("properties").objectForKeyedSubscript("price").toString()
            var annotation = ListingAnnotation()
            annotation.coordinate = CLLocationCoordinate2D(latitude: lat,
                longitude: lon)
            annotation.title = "Listing"
            annotation.subtitle = price
            annotations.append(annotation)
        }

        annotations.append(MGLPolygon(coordinates: &coordinates, count: UInt(coordinates.count)))
        annotations.append(KeyLine(coordinates: &coordinates, count: UInt(coordinates.count)))

        var connector = [coordinates.last!, coordinates.first!]

        annotations.append(KeyLine(coordinates: &connector, count: UInt(connector.count)))

        map.addAnnotations(annotations)

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(NSEC_PER_SEC)), dispatch_get_main_queue()) { [unowned self] in
            self.cancelSearch()
        }
    }

    func mapView(mapView: MGLMapView!, alphaForShapeAnnotation annotation: MGLShape!) -> CGFloat {
        return (annotation is MGLPolyline ? 1.0 : 0.25)
    }

    func mapView(mapView: MGLMapView!, fillColorForPolygonAnnotation annotation: MGLPolygon!) -> UIColor! {
        return UIColor.blueColor()
    }

    func mapView(mapView: MGLMapView!, lineWidthForPolylineAnnotation annotation: MGLPolyline!) -> CGFloat {
        return (annotation is KeyLine ? 2 : 3)
    }

    func mapView(mapView: MGLMapView!, strokeColorForShapeAnnotation annotation: MGLShape!) -> UIColor! {
        return (annotation is KeyLine ? UIColor.blueColor() : UIColor.purpleColor())
    }

    func mapView(mapView: MGLMapView!, annotationCanShowCallout annotation: MGLAnnotation!) -> Bool {
        return true
    }

    func mapView(mapView: MGLMapView!, leftCalloutAccessoryViewForAnnotation annotation: MGLAnnotation!) -> UIView! {
        return (annotation is ListingAnnotation ? UIImageView(image: UIImage(named: "listing_thumb.jpg")) : nil)
    }

    func mapView(mapView: MGLMapView!, rightCalloutAccessoryViewForAnnotation annotation: MGLAnnotation!) -> UIView! {
        return (annotation is ListingAnnotation ? UIButton.buttonWithType(.DetailDisclosure) as! UIView : nil)
    }

    func mapView(mapView: MGLMapView!, annotation: MGLAnnotation!, calloutAccessoryControlTapped control: UIControl!) {
        if (startingPoint != nil) {
            map.deselectAnnotation(annotation, animated: false)

            if (routeLine != nil) {
                map.removeAnnotation(routeLine)
            }

            let hud = MBProgressHUD(view: view)
            hud.mode = .Indeterminate
            hud.labelText = "Routing..."
            view.addSubview(hud)
            hud.show(true)
            hud.hide(true, afterDelay: 2.0)

            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, Int64(2) * Int64(NSEC_PER_SEC)), dispatch_get_main_queue()) { [unowned self] in
                var coordinates = self.route!
                self.routeLine = RouteLine(coordinates: &coordinates, count: UInt(coordinates.count))
                self.map.addAnnotation(self.routeLine)
            }
        }
    }

    func mapView(mapView: MGLMapView!, symbolNameForAnnotation annotation: MGLAnnotation!) -> String! {
        return (annotation is ListingAnnotation ? "secondary_marker" : "default_marker")
    }

    func mapView(mapView: MGLMapView!, didSelectAnnotation annotation: MGLAnnotation!) {
        if (annotation.title == "Listing") {
            geocoder.cancelGeocode()
            geocoder.reverseGeocodeLocation(CLLocation(latitude: annotation.coordinate.latitude,
                longitude: annotation.coordinate.longitude),
                completionHandler: { [unowned self] (results, error) in
                    let streetAddress = (results.first! as! MBPlacemark).name.componentsSeparatedByString(",").first!
                    (annotation as! MGLPointAnnotation).title = streetAddress
                    self.map.deselectAnnotation(annotation, animated: false)
                    self.map.selectAnnotation(annotation, animated: false)
            })
        }
        if (startingPoint != nil) {
            directions?.cancel()
            directions = MBDirections(request:
                MBDirectionsRequest(sourceCoordinate: startingPoint!.coordinate,
                    destinationCoordinate: annotation.coordinate),
                accessToken: MGLAccountManager.accessToken())
            directions!.calculateDirectionsWithCompletionHandler { [unowned self] (response, error) in
                if (response?.routes.count > 0) {
                    var routeGeometry = response!.routes.first!.geometry
                    self.route = routeGeometry
                }
            }
        }
    }

}
