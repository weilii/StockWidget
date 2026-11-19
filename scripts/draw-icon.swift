import AppKit
import Foundation

let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 80, y: 80, width: 864, height: 864)
NSColor(calibratedRed: 0.07, green: 0.15, blue: 0.17, alpha: 1).setFill()
NSBezierPath(roundedRect: rect, xRadius: 190, yRadius: 190).fill()
let chart = NSBezierPath()
chart.move(to: NSPoint(x: 220, y: 360))
for p in [(330, 440), (430, 405), (555, 610), (655, 545), (805, 720)] { chart.line(to: NSPoint(x: p.0, y: p.1)) }
chart.lineWidth = 52; chart.lineCapStyle = .round; chart.lineJoinStyle = .round
NSColor(calibratedRed: 0.32, green: 0.84, blue: 0.72, alpha: 1).setStroke(); chart.stroke()
NSColor.white.withAlphaComponent(0.14).setStroke()
let baseline = NSBezierPath(); baseline.move(to: NSPoint(x: 220, y: 275)); baseline.line(to: NSPoint(x: 805, y: 275)); baseline.lineWidth = 10; baseline.lineCapStyle = .round; baseline.stroke()
image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { fatalError("Icon rendering failed") }
// A modern icns can contain one PNG-backed 1024px representation (ic10).
var output = Data("icns".utf8)
func int32(_ value: Int) -> Data { var v = UInt32(value).bigEndian; return withUnsafeBytes(of: &v) { Data($0) } }
output.append(int32(png.count + 16)); output.append(Data("ic10".utf8)); output.append(int32(png.count + 8)); output.append(png)
try output.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
