// Renders EasyDLArt/icon-1024.png. Original artwork: a rounded tile with a download
// arrow dropping into a tray. Run via `swift EasyDLArt/make-icon.swift <out.png>`.
import AppKit

let size: CGFloat = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }
ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

// Tile: macOS app icons sit inside a margin rather than filling the square.
let inset = size * 0.085
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let tile = NSBezierPath(roundedRect: rect,
                        xRadius: rect.width * 0.2237,
                        yRadius: rect.width * 0.2237)
tile.addClip()

NSGradient(colors: [
    NSColor(srgbRed: 0.35, green: 0.56, blue: 0.99, alpha: 1),
    NSColor(srgbRed: 0.42, green: 0.21, blue: 0.82, alpha: 1),
])?.draw(in: rect, angle: -90)

// Soft highlight across the top so the tile doesn't read as flat.
NSColor(white: 1, alpha: 0.13).setFill()
NSBezierPath(ovalIn: NSRect(x: rect.minX - rect.width * 0.2,
                            y: rect.midY + rect.height * 0.12,
                            width: rect.width * 1.4,
                            height: rect.height * 0.95)).fill()

NSColor.white.setFill()

// Arrow shaft.
let cx = size / 2
let shaftW = size * 0.115
let shaftTop = size * 0.735
let shaftBottom = size * 0.435
NSBezierPath(roundedRect: NSRect(x: cx - shaftW / 2, y: shaftBottom,
                                 width: shaftW, height: shaftTop - shaftBottom),
             xRadius: shaftW / 2, yRadius: shaftW / 2).fill()

// Arrow head.
let headHalf = size * 0.155
let headTip = size * 0.315
let head = NSBezierPath()
head.move(to: NSPoint(x: cx, y: headTip))
head.line(to: NSPoint(x: cx - headHalf, y: headTip + headHalf * 1.05))
head.line(to: NSPoint(x: cx + headHalf, y: headTip + headHalf * 1.05))
head.close()
head.lineJoinStyle = .round
head.lineWidth = size * 0.055
head.stroke()
head.fill()

// Tray the arrow lands in.
let trayW = size * 0.42
let trayH = size * 0.072
NSBezierPath(roundedRect: NSRect(x: cx - trayW / 2, y: size * 0.175,
                                 width: trayW, height: trayH),
             xRadius: trayH / 2, yRadius: trayH / 2).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
