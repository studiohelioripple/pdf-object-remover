import Foundation
import CoreImage
import Vision
import AppKit
import CoreGraphics
import PDFKit

// =========================================================================
// PDF Object Remover & Cross-Slide Healer (pdf_healer)
// Detects target objects on an anchor page and applies page-adaptive
// 2D gradient, grain-matched, and perimeter-feathered healing across all pages.
// Part of the pdf-object-remover skill on macOS.
// =========================================================================

struct BackgroundAnalysis: Codable {
    let dominantRGB: [Int]         // 0..255
    let keynoteRGB: [Int]          // 0..65535
    let hex: String                // #RRGGBB
    let isGradient: Bool
    let gradientVariance: Double
    let noiseVariance: Double
    let planeParamsR: [Double]     // a, b, c (R = a*x + b*y + c)
    let planeParamsG: [Double]     // a, b, c
    let planeParamsB: [Double]     // a, b, c
}

struct DetectedObjectInfo: Codable {
    let anchorPage: Int
    let textMatched: [String]
    let pixelBox: [Double]         // [x, y, w, h] on anchor page at rendered DPI
    let normalizedBox: [Double]    // [x, y, w, h] in 0.0..1.0
    let pointsBox: [Double]        // [x, y, w, h] in 72 DPI PDF points
    let anchorPageWidth: Int
    let anchorPageHeight: Int
    let background: BackgroundAnalysis
}

struct PDFRemoverOptions {
    var inputPath: String = ""
    var outputPath: String = ""
    var anchorPage: Int = 1         // 1-based index
    var zone: String = "bottom-right"
    
    // Normalized zone boundaries (0.0 to 1.0, top-left is 0,0)
    var zoneMinX: CGFloat = 0.65
    var zoneMaxX: CGFloat = 1.00
    var zoneMinY: CGFloat = 0.80
    var zoneMaxY: CGFloat = 1.00
    
    var textFilter: String? = nil
    var explicitBox: CGRect? = nil
    var isExplicitNormalized: Bool = false
    
    var healingMode: String = "auto" // "auto", "gradient", "solid", "inpaint"
    var pdfDPI: CGFloat = 300.0
    var pageRangeStr: String = "all"
    var excludePagesStr: String = ""
    
    var padding: Int = 4
    var featherRadius: Int = 4
    var extendRight: Bool = false
    var extendBottom: Bool = false
    
    var previewMaskPath: String? = nil
    var inspectOnly: Bool = false
    var jsonOutput: Bool = false
}

// MARK: - CLI Parsing

func printUsage() {
    let usage = """
    PDF-Object-Remover: Native Multi-Page Slide & Document Healing Engine (pdf_healer)
    Usage: pdf_healer --input <input.pdf> --output <output.pdf> [options]

    Anchor Page & Object Targeting:
      --anchor-page, -p <n>     Reference page to detect target object on (default: 1)
      --filter, -f <query>      Text query or substring to detect via Apple Vision OCR
      --zone, -z <name>         Spatial search zone preset:
                                • bottom-right (default: right 35%, bottom 20%)
                                • bottom-right-corner / logo (right 25%, bottom 12%)
                                • bottom-left (left 35%, bottom 20%)
                                • top-right (right 35%, top 20%)
                                • top-left (left 35%, top 20%)
                                • footer / bottom-bar (full width, bottom 12%)
                                • header / top-bar (full width, top 12%)
                                • all (entire page)
                                • custom (use --min-x, --max-x, --min-y, --max-y)
      --min-x, --max-x <0-1>    Custom zone horizontal ratio range (0.0 = left, 1.0 = right)
      --min-y, --max-y <0-1>    Custom zone vertical ratio range (0.0 = top, 1.0 = bottom)
      --box <b>                 Explicit box "x,y,w,h" (either 0.0..1.0 normalized or pixel coordinates)
      --padding <px>            Margin expansion around detected object in pixels (default: 4)
      --extend-right            Extend detected area flush to the right boundary of the page
      --extend-bottom           Extend detected area flush to the bottom boundary of the page

    Healing & Inpainting Modes:
      --mode, -m <mode>         Healing strategy per page:
                                • auto (default: detects gradient vs solid + grain synthesis)
                                • gradient (2D planar surface detrending + noise synthesis)
                                • solid (dominant perimeter border color)
      --feather <px>            Edge feathering ramp width in pixels (default: 4)

    PDF Processing & Inspection:
      --dpi <number>            Rendering resolution for PDF rasterization (default: 300 DPI)
      --pages <range>           Pages to apply healing across: "all" (default), "1-5", "2,4,6"
      --exclude-pages <range>   Pages to exempt from healing
      --preview-mask <path.png> Save high-res preview of anchor page with highlighted detection mask
      --inspect                 Inspect anchor page, print detected coordinates and text, and exit
      --json                    Output inspection and processing stats in structured JSON format
      --help, -h                Show this help message
    """
    fputs(usage + "\n", stderr)
}

func parseArgs() -> PDFRemoverOptions? {
    var opts = PDFRemoverOptions()
    let args = CommandLine.arguments
    if args.count <= 1 {
        printUsage()
        return nil
    }
    
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--input", "-i":
            if i + 1 < args.count { opts.inputPath = args[i+1]; i += 1 }
        case "--output", "-o":
            if i + 1 < args.count { opts.outputPath = args[i+1]; i += 1 }
        case "--anchor-page", "-p":
            if i + 1 < args.count, let val = Int(args[i+1]) { opts.anchorPage = max(1, val); i += 1 }
        case "--filter", "-f", "--query", "-q":
            if i + 1 < args.count { opts.textFilter = args[i+1]; i += 1 }
        case "--zone", "-z":
            if i + 1 < args.count {
                opts.zone = args[i+1].lowercased()
                i += 1
                switch opts.zone {
                case "bottom-right":
                    opts.zoneMinX = 0.65; opts.zoneMaxX = 1.00; opts.zoneMinY = 0.80; opts.zoneMaxY = 1.00
                case "bottom-right-corner", "corner", "logo", "corner-stamp":
                    opts.zoneMinX = 0.75; opts.zoneMaxX = 1.00; opts.zoneMinY = 0.88; opts.zoneMaxY = 1.00
                case "bottom-left":
                    opts.zoneMinX = 0.00; opts.zoneMaxX = 0.35; opts.zoneMinY = 0.80; opts.zoneMaxY = 1.00
                case "top-right":
                    opts.zoneMinX = 0.65; opts.zoneMaxX = 1.00; opts.zoneMinY = 0.00; opts.zoneMaxY = 0.20
                case "top-left":
                    opts.zoneMinX = 0.00; opts.zoneMaxX = 0.35; opts.zoneMinY = 0.00; opts.zoneMaxY = 0.20
                case "footer", "bottom-bar":
                    opts.zoneMinX = 0.00; opts.zoneMaxX = 1.00; opts.zoneMinY = 0.88; opts.zoneMaxY = 1.00
                case "header", "top-bar":
                    opts.zoneMinX = 0.00; opts.zoneMaxX = 1.00; opts.zoneMinY = 0.00; opts.zoneMaxY = 0.12
                case "all":
                    opts.zoneMinX = 0.00; opts.zoneMaxX = 1.00; opts.zoneMinY = 0.00; opts.zoneMaxY = 1.00
                default: break
                }
            }
        case "--min-x":
            if i + 1 < args.count, let val = Double(args[i+1]) { opts.zoneMinX = CGFloat(val); i += 1 }
        case "--max-x":
            if i + 1 < args.count, let val = Double(args[i+1]) { opts.zoneMaxX = CGFloat(val); i += 1 }
        case "--min-y":
            if i + 1 < args.count, let val = Double(args[i+1]) { opts.zoneMinY = CGFloat(val); i += 1 }
        case "--max-y":
            if i + 1 < args.count, let val = Double(args[i+1]) { opts.zoneMaxY = CGFloat(val); i += 1 }
        case "--box", "-b":
            if i + 1 < args.count {
                let parts = args[i+1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 4 {
                    opts.explicitBox = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                    opts.isExplicitNormalized = (parts[0] <= 1.0 && parts[1] <= 1.0 && parts[2] <= 1.0 && parts[3] <= 1.0)
                }
                i += 1
            }
        case "--mode", "-m":
            if i + 1 < args.count { opts.healingMode = args[i+1].lowercased(); i += 1 }
        case "--dpi":
            if i + 1 < args.count, let val = Double(args[i+1]) { opts.pdfDPI = CGFloat(val); i += 1 }
        case "--pages":
            if i + 1 < args.count { opts.pageRangeStr = args[i+1]; i += 1 }
        case "--exclude-pages":
            if i + 1 < args.count { opts.excludePagesStr = args[i+1]; i += 1 }
        case "--padding":
            if i + 1 < args.count, let val = Int(args[i+1]) { opts.padding = val; i += 1 }
        case "--feather":
            if i + 1 < args.count, let val = Int(args[i+1]) { opts.featherRadius = val; i += 1 }
        case "--extend-right":
            opts.extendRight = true
        case "--extend-bottom":
            opts.extendBottom = true
        case "--preview-mask":
            if i + 1 < args.count { opts.previewMaskPath = args[i+1]; i += 1 }
        case "--inspect":
            opts.inspectOnly = true
        case "--json":
            opts.jsonOutput = true
        case "--help", "-h":
            printUsage()
            return nil
        default:
            fputs("Warning: Unknown argument '\(arg)'\n", stderr)
        }
        i += 1
    }
    
    if opts.inputPath.isEmpty {
        fputs("Error: Missing --input PDF path.\n", stderr)
        return nil
    }
    if !opts.inspectOnly && opts.outputPath.isEmpty {
        fputs("Error: Missing --output PDF path.\n", stderr)
        return nil
    }
    
    return opts
}

// MARK: - Page Parsing Utility

func parsePageSet(rangeStr: String, totalPages: Int, defaultAll: Bool = true) -> Set<Int> {
    let trimmed = rangeStr.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
        return defaultAll ? Set(0..<totalPages) : Set<Int>()
    }
    if trimmed.lowercased() == "all" {
        return Set(0..<totalPages)
    }
    
    var set = Set<Int>()
    let tokens = rangeStr.split(separator: ",")
    for token in tokens {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.contains("-") {
            let sub = t.split(separator: "-")
            if sub.count == 2, let start = Int(sub[0]), let end = Int(sub[1]) {
                for p in min(start, end)...max(start, end) {
                    if p >= 1 && p <= totalPages { set.insert(p - 1) }
                }
            }
        } else if let p = Int(t) {
            if p >= 1 && p <= totalPages { set.insert(p - 1) }
        }
    }
    return set
}

// MARK: - CoreGraphics PDF Rendering

func renderPDFPageToCGImage(page: PDFPage, dpi: CGFloat) -> (CGImage?, Int, Int) {
    let bounds = page.bounds(for: .mediaBox)
    let scale = dpi / 72.0
    let pWidth = max(1, Int(bounds.width * scale))
    let pHeight = max(1, Int(bounds.height * scale))
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = pWidth * 4
    guard let ctx = CGContext(
        data: nil,
        width: pWidth,
        height: pHeight,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return (nil, pWidth, pHeight)
    }
    
    // Background fill white
    ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(pWidth), height: CGFloat(pHeight)))
    
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: ctx)
    ctx.restoreGState()
    
    let image = ctx.makeImage()
    return (image, pWidth, pHeight)
}

// MARK: - Background Analysis (2D Surface Plane Fitting & Noise Estimation)

func analyzePerimeterBackground(
    cgImage: CGImage,
    box: CGRect,
    margin: Int = 14
) -> BackgroundAnalysis {
    let width = cgImage.width
    let height = cgImage.height
    
    let bx = Int(box.origin.x)
    let by = Int(box.origin.y)
    let bw = Int(box.width)
    let bh = Int(box.height)
    
    let x1 = max(0, min(width - 1, bx))
    let y1 = max(0, min(height - 1, by))
    let x2 = max(x1 + 1, min(width, bx + bw))
    let y2 = max(y1 + 1, min(height, by + bh))
    
    let outerY1 = max(0, y1 - margin)
    let outerY2 = min(height, y2 + margin)
    let outerX1 = max(0, x1 - margin)
    let outerX2 = min(width, x2 + margin)
    
    guard let dataProvider = cgImage.dataProvider,
          let data = dataProvider.data,
          let ptr = CFDataGetBytePtr(data) else {
        return BackgroundAnalysis(
            dominantRGB: [255, 255, 255],
            keynoteRGB: [65535, 65535, 65535],
            hex: "#FFFFFF",
            isGradient: false,
            gradientVariance: 0,
            noiseVariance: 0,
            planeParamsR: [0, 0, 255],
            planeParamsG: [0, 0, 255],
            planeParamsB: [0, 0, 255]
        )
    }
    
    let bytesPerRow = cgImage.bytesPerRow
    let bpp = cgImage.bitsPerPixel / 8
    
    var coordsX: [Double] = []
    var coordsY: [Double] = []
    var rVals: [Double] = []
    var gVals: [Double] = []
    var bVals: [Double] = []
    
    func samplePixel(x: Int, y: Int) {
        let offset = y * bytesPerRow + x * bpp
        let r = Double(ptr[offset])
        let g = Double(ptr[offset + 1])
        let b = Double(ptr[offset + 2])
        coordsX.append(Double(x))
        coordsY.append(Double(y))
        rVals.append(r)
        gVals.append(g)
        bVals.append(b)
    }
    
    // Top border strip
    for y in outerY1..<y1 {
        for x in outerX1..<outerX2 { samplePixel(x: x, y: y) }
    }
    // Bottom border strip
    for y in y2..<outerY2 {
        for x in outerX1..<outerX2 { samplePixel(x: x, y: y) }
    }
    // Left border strip
    for y in y1..<y2 {
        for x in outerX1..<x1 { samplePixel(x: x, y: y) }
    }
    // Right border strip
    for y in y1..<y2 {
        for x in x2..<outerX2 { samplePixel(x: x, y: y) }
    }
    
    if rVals.isEmpty {
        return BackgroundAnalysis(
            dominantRGB: [255, 255, 255],
            keynoteRGB: [65535, 65535, 65535],
            hex: "#FFFFFF",
            isGradient: false,
            gradientVariance: 0,
            noiseVariance: 0,
            planeParamsR: [0, 0, 255],
            planeParamsG: [0, 0, 255],
            planeParamsB: [0, 0, 255]
        )
    }
    
    let sortedR = rVals.sorted()
    let sortedG = gVals.sorted()
    let sortedB = bVals.sorted()
    let mid = sortedR.count / 2
    let medR = Int(sortedR[mid])
    let medG = Int(sortedG[mid])
    let medB = Int(sortedB[mid])
    
    let meanR = rVals.reduce(0, +) / Double(rVals.count)
    let varR = rVals.map { pow($0 - meanR, 2) }.reduce(0, +) / Double(rVals.count)
    let isGrad = varR > 6.0
    
    // Fit 2D Plane: V(x, y) = a*x + b*y + c
    func fitPlane(values: [Double]) -> [Double] {
        let n = Double(coordsX.count)
        var sumX = 0.0, sumY = 0.0, sumX2 = 0.0, sumY2 = 0.0, sumXY = 0.0
        var sumV = 0.0, sumXV = 0.0, sumYV = 0.0
        
        for i in 0..<coordsX.count {
            let x = coordsX[i]
            let y = coordsY[i]
            let v = values[i]
            sumX += x; sumY += y
            sumX2 += x * x; sumY2 += y * y; sumXY += x * y
            sumV += v; sumXV += x * v; sumYV += y * v
        }
        
        let det = sumX2 * (sumY2 * n - sumY * sumY) - sumXY * (sumXY * n - sumX * sumY) + sumX * (sumXY * sumY - sumX * sumY2)
        if abs(det) < 1e-7 {
            return [0.0, 0.0, sumV / n]
        }
        
        let a = ((sumXV * (sumY2 * n - sumY * sumY)) - (sumXY * (sumYV * n - sumV * sumY)) + (sumX * (sumYV * sumY - sumV * sumY2))) / det
        let b = ((sumX2 * (sumYV * n - sumV * sumY)) - (sumXV * (sumXY * n - sumX * sumY)) + (sumX * (sumXY * sumV - sumX * sumYV))) / det
        let c = ((sumX2 * (sumY2 * sumV - sumY * sumYV)) - (sumXY * (sumXY * sumV - sumX * sumYV)) + (sumXV * (sumXY * sumY - sumX * sumY2))) / det
        
        return [a, b, c]
    }
    
    let planeR = fitPlane(values: rVals)
    let planeG = fitPlane(values: gVals)
    let planeB = fitPlane(values: bVals)
    
    // Estimate high-frequency texture noise using Median Absolute Deviation (MAD) of residuals
    var residuals: [Double] = []
    for i in 0..<coordsX.count {
        let x = coordsX[i]
        let y = coordsY[i]
        let predR = planeR[0] * x + planeR[1] * y + planeR[2]
        residuals.append(rVals[i] - predR)
    }
    residuals.sort()
    let medRes = residuals[residuals.count / 2]
    var absDevs = residuals.map { abs($0 - medRes) }
    absDevs.sort()
    let mad = absDevs[absDevs.count / 2]
    let noiseVar = pow(1.4826 * mad, 2)
    
    let kR = min(65535, max(0, Int(Double(medR) * 257.0)))
    let kG = min(65535, max(0, Int(Double(medG) * 257.0)))
    let kB = min(65535, max(0, Int(Double(medB) * 257.0)))
    let hexStr = String(format: "#%02X%02X%02X", medR, medG, medB)
    
    return BackgroundAnalysis(
        dominantRGB: [medR, medG, medB],
        keynoteRGB: [kR, kG, kB],
        hex: hexStr,
        isGradient: isGrad,
        gradientVariance: varR,
        noiseVariance: noiseVar,
        planeParamsR: planeR,
        planeParamsG: planeG,
        planeParamsB: planeB
    )
}

// MARK: - Vision OCR & Spatial Object Detection on Anchor Page

func detectObjectOnAnchorPage(
    anchorImage: CGImage,
    opts: PDFRemoverOptions
) -> (CGRect, [String], BackgroundAnalysis) {
    let imgW = CGFloat(anchorImage.width)
    let imgH = CGFloat(anchorImage.height)
    
    // 1. If explicit box was provided
    if let explicit = opts.explicitBox {
        let box: CGRect
        if opts.isExplicitNormalized {
            box = CGRect(
                x: explicit.origin.x * imgW,
                y: explicit.origin.y * imgH,
                width: explicit.width * imgW,
                height: explicit.height * imgH
            )
        } else {
            box = explicit
        }
        let bg = analyzePerimeterBackground(cgImage: anchorImage, box: box)
        return (box, ["<explicit-box>"], bg)
    }
    
    // 2. Perform Apple Vision OCR text recognition
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    
    let handler = VNImageRequestHandler(cgImage: anchorImage, options: [:])
    try? handler.perform([request])
    let observations = request.results ?? []
    
    // Define zone in pixel coordinates (Vision normalized coordinates have (0,0) at bottom-left)
    // Convert options zone (where top is 0.0) to Vision coordinates (where bottom is 0.0)
    let zonePixelX = opts.zoneMinX * imgW
    let zonePixelY = opts.zoneMinY * imgH
    let zonePixelW = (opts.zoneMaxX - opts.zoneMinX) * imgW
    let zonePixelH = (opts.zoneMaxY - opts.zoneMinY) * imgH
    let zoneRect = CGRect(x: zonePixelX, y: zonePixelY, width: zonePixelW, height: zonePixelH)
    
    var matchedBoxes: [CGRect] = []
    var matchedTexts: [String] = []
    
    for obs in observations {
        guard let candidate = obs.topCandidates(1).first else { continue }
        let textStr = candidate.string
        
        // Vision boundingBox has y=0 at bottom.
        // Convert to standard Top-Left origin:
        let obsNormBox = obs.boundingBox
        let obsPixelX = obsNormBox.origin.x * imgW
        let obsPixelY = (1.0 - obsNormBox.origin.y - obsNormBox.height) * imgH
        let obsPixelW = obsNormBox.width * imgW
        let obsPixelH = obsNormBox.height * imgH
        let obsRect = CGRect(x: obsPixelX, y: obsPixelY, width: obsPixelW, height: obsPixelH)
        
        // Check intersection with zone
        if obsRect.intersects(zoneRect) {
            if let filter = opts.textFilter, !filter.isEmpty {
                if textStr.localizedCaseInsensitiveContains(filter) {
                    matchedBoxes.append(obsRect)
                    matchedTexts.append(textStr)
                }
            } else {
                matchedBoxes.append(obsRect)
                matchedTexts.append(textStr)
            }
        }
    }
    
    let finalBox: CGRect
    if matchedBoxes.isEmpty {
        // Fallback to zone bounding box
        finalBox = zoneRect
    } else {
        var minX = matchedBoxes[0].minX
        var minY = matchedBoxes[0].minY
        var maxX = matchedBoxes[0].maxX
        var maxY = matchedBoxes[0].maxY
        for b in matchedBoxes.dropFirst() {
            minX = min(minX, b.minX)
            minY = min(minY, b.minY)
            maxX = max(maxX, b.maxX)
            maxY = max(maxY, b.maxY)
        }
        
        let pad = CGFloat(opts.padding)
        let clampedX = max(0, minX - pad)
        let clampedY = max(0, minY - pad)
        var clampedW = min(imgW - clampedX, (maxX - minX) + pad * 2)
        var clampedH = min(imgH - clampedY, (maxY - minY) + pad * 2)
        
        if opts.extendRight {
            clampedW = imgW - clampedX
        }
        if opts.extendBottom {
            clampedH = imgH - clampedY
        }
        
        finalBox = CGRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH)
    }
    
    let bg = analyzePerimeterBackground(cgImage: anchorImage, box: finalBox)
    return (finalBox, matchedTexts, bg)
}

// MARK: - High-Performance In-Memory Slide Healer

func healPageImage(
    pageImage: CGImage,
    targetBox: CGRect,
    bgAnalysis: BackgroundAnalysis,
    mode: String,
    featherRadius: Int
) -> CGImage? {
    let width = pageImage.width
    let height = pageImage.height
    
    let bx = Int(targetBox.origin.x)
    let by = Int(targetBox.origin.y)
    let bw = Int(targetBox.width)
    let bh = Int(targetBox.height)
    
    let x1 = max(0, min(width - 1, bx))
    let y1 = max(0, min(height - 1, by))
    let x2 = max(x1 + 1, min(width, bx + bw))
    let y2 = max(y1 + 1, min(height, by + bh))
    
    let boxW = x2 - x1
    let boxH = y2 - y1
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    
    // Draw original image into context
    context.draw(pageImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    guard let dataPtr = context.data?.bindMemory(to: UInt8.self, capacity: height * bytesPerRow) else {
        return nil
    }
    
    let pR = bgAnalysis.planeParamsR
    let pG = bgAnalysis.planeParamsG
    let pB = bgAnalysis.planeParamsB
    
    let domR = Double(bgAnalysis.dominantRGB[0])
    let domG = Double(bgAnalysis.dominantRGB[1])
    let domB = Double(bgAnalysis.dominantRGB[2])
    
    let useGradient = (mode == "gradient") || (mode == "auto" && bgAnalysis.isGradient)
    let noiseAmp = min(sqrt(bgAnalysis.noiseVariance) * 1.732, 12.0)
    
    for localY in 0..<boxH {
        let globalY = y1 + localY
        
        for localX in 0..<boxW {
            let globalX = x1 + localX
            
            var reconR: Double
            var reconG: Double
            var reconB: Double
            
            if useGradient {
                reconR = pR[0] * Double(globalX) + pR[1] * Double(globalY) + pR[2]
                reconG = pG[0] * Double(globalX) + pG[1] * Double(globalY) + pG[2]
                reconB = pB[0] * Double(globalX) + pB[1] * Double(globalY) + pB[2]
            } else {
                reconR = domR
                reconG = domG
                reconB = domB
            }
            
            // Add subtle noise grain to prevent flat plastic look
            if noiseAmp > 0.5 {
                let noise = Double.random(in: -noiseAmp...noiseAmp)
                reconR += noise
                reconG += noise
                reconB += noise
            }
            
            reconR = min(255.0, max(0.0, reconR))
            reconG = min(255.0, max(0.0, reconG))
            reconB = min(255.0, max(0.0, reconB))
            
            var weight = 1.0
            if featherRadius > 0 {
                let distLeft = Double(localX)
                let distRight = Double(boxW - 1 - localX)
                let distTop = Double(localY)
                let distBottom = Double(boxH - 1 - localY)
                let minDist = min(distLeft, distRight, distTop, distBottom)
                if minDist < Double(featherRadius) {
                    weight = (minDist + 1.0) / Double(featherRadius + 1)
                }
            }
            
            let pixelOffset = globalY * bytesPerRow + globalX * bytesPerPixel
            let origR = Double(dataPtr[pixelOffset])
            let origG = Double(dataPtr[pixelOffset + 1])
            let origB = Double(dataPtr[pixelOffset + 2])
            
            let finalR = origR * (1.0 - weight) + reconR * weight
            let finalG = origG * (1.0 - weight) + reconG * weight
            let finalB = origB * (1.0 - weight) + reconB * weight
            
            dataPtr[pixelOffset] = UInt8(finalR)
            dataPtr[pixelOffset + 1] = UInt8(finalG)
            dataPtr[pixelOffset + 2] = UInt8(finalB)
            dataPtr[pixelOffset + 3] = 255
        }
    }
    
    return context.makeImage()
}

// MARK: - Diagnostic Preview Mask Generator

func savePreviewMask(
    anchorImage: CGImage,
    box: CGRect,
    outPath: String
) {
    let width = anchorImage.width
    let height = anchorImage.height
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    
    ctx.draw(anchorImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    // Draw translucent red fill
    ctx.setFillColor(red: 1.0, green: 0.15, blue: 0.15, alpha: 0.40)
    ctx.fill(box)
    
    // Draw bright green border
    ctx.setStrokeColor(red: 0.0, green: 1.0, blue: 0.25, alpha: 0.95)
    ctx.setLineWidth(4.0)
    ctx.stroke(box)
    
    if let outImage = ctx.makeImage() {
        let url = URL(fileURLWithPath: outPath) as CFURL
        if let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, outImage, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

// MARK: - Main Application Pipeline

func main() {
    guard let opts = parseArgs() else { exit(1) }
    
    let inputURL = URL(fileURLWithPath: opts.inputPath)
    guard let inputDoc = PDFDocument(url: inputURL) else {
        fputs("Error: Could not open PDF document at \(opts.inputPath)\n", stderr)
        exit(1)
    }
    
    let totalPages = inputDoc.pageCount
    if totalPages == 0 {
        fputs("Error: PDF document has 0 pages.\n", stderr)
        exit(1)
    }
    
    let anchorIdx = min(max(0, opts.anchorPage - 1), totalPages - 1)
    guard let anchorPage = inputDoc.page(at: anchorIdx) else {
        fputs("Error: Could not retrieve anchor page \(opts.anchorPage)\n", stderr)
        exit(1)
    }
    
    if !opts.jsonOutput {
        print("📄 Document: '\(inputURL.lastPathComponent)' (\(totalPages) pages, target DPI: \(Int(opts.pdfDPI)))")
        print("🔍 Addressing target object on Anchor Page \(anchorIdx + 1)...")
    }
    
    // 1. Render Anchor Page
    let (anchorCG, anchorW, anchorH) = renderPDFPageToCGImage(page: anchorPage, dpi: opts.pdfDPI)
    guard let anchorImg = anchorCG else {
        fputs("Error: Failed to rasterize anchor page.\n", stderr)
        exit(1)
    }
    
    // 2. Detect object on Anchor Page
    let (detectedBox, matchedTexts, anchorBG) = detectObjectOnAnchorPage(anchorImage: anchorImg, opts: opts)
    
    // Compute normalized coordinates (0.0 to 1.0)
    let normX = Double(detectedBox.origin.x / CGFloat(anchorW))
    let normY = Double(detectedBox.origin.y / CGFloat(anchorH))
    let normW = Double(detectedBox.width / CGFloat(anchorW))
    let normH = Double(detectedBox.height / CGFloat(anchorH))
    
    let anchorMediaBounds = anchorPage.bounds(for: .mediaBox)
    let ptX = normX * Double(anchorMediaBounds.width)
    let ptY = normY * Double(anchorMediaBounds.height)
    let ptW = normW * Double(anchorMediaBounds.width)
    let ptH = normH * Double(anchorMediaBounds.height)
    
    let detectedInfo = DetectedObjectInfo(
        anchorPage: anchorIdx + 1,
        textMatched: matchedTexts,
        pixelBox: [Double(detectedBox.origin.x), Double(detectedBox.origin.y), Double(detectedBox.width), Double(detectedBox.height)],
        normalizedBox: [normX, normY, normW, normH],
        pointsBox: [ptX, ptY, ptW, ptH],
        anchorPageWidth: anchorW,
        anchorPageHeight: anchorH,
        background: anchorBG
    )
    
    // Diagnostic Preview Mask
    if let previewPath = opts.previewMaskPath {
        savePreviewMask(anchorImage: anchorImg, box: detectedBox, outPath: previewPath)
        if !opts.jsonOutput {
            print("  📸 Saved diagnostic preview mask to: \(previewPath)")
        }
    }
    
    if opts.inspectOnly {
        if opts.jsonOutput {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            if let data = try? encoder.encode(detectedInfo), let str = String(data: data, encoding: .utf8) {
                print(str)
            }
        } else {
            print("\n🎯 Detection Summary on Page \(anchorIdx + 1):")
            print("  • Normalized Box: [x: \(String(format: "%.4f", normX)), y: \(String(format: "%.4f", normY)), w: \(String(format: "%.4f", normW)), h: \(String(format: "%.4f", normH))]")
            print("  • Pixel Box (\(Int(opts.pdfDPI)) DPI): \(Int(detectedBox.origin.x)),\(Int(detectedBox.origin.y)) \(Int(detectedBox.width))x\(Int(detectedBox.height)) px")
            print("  • PDF Points (72 DPI): \(String(format: "%.1f,%.1f %.1fx%.1f pt", ptX, ptY, ptW, ptH))")
            if !matchedTexts.isEmpty {
                print("  • Matched Text Items: \(matchedTexts.joined(separator: " | "))")
            }
            print("  • Background: \(anchorBG.hex) (Gradient: \(anchorBG.isGradient), Noise Var: \(String(format: "%.2f", anchorBG.noiseVariance)))")
        }
        return
    }
    
    // 3. Propagate and Heal Across Target Pages
    let targetPageSet = parsePageSet(rangeStr: opts.pageRangeStr, totalPages: totalPages, defaultAll: true)
    let excludeSet = parsePageSet(rangeStr: opts.excludePagesStr, totalPages: totalPages, defaultAll: false)
    
    let activePages = targetPageSet.subtracting(excludeSet)
    if !opts.jsonOutput {
        print("🩹 Applying healing across \(activePages.count) slide page(s) at matching position...")
    }
    
    let outDoc = PDFDocument()
    var healedCount = 0
    let startTime = CFAbsoluteTimeGetCurrent()
    
    for pageIdx in 0..<totalPages {
        guard let page = inputDoc.page(at: pageIdx) else { continue }
        let pageMedia = page.bounds(for: .mediaBox)
        
        if !activePages.contains(pageIdx) {
            outDoc.insert(page, at: outDoc.pageCount)
            continue
        }
        
        // Render this page at DPI
        let (pageCG, pW, pH) = renderPDFPageToCGImage(page: page, dpi: opts.pdfDPI)
        guard let pImage = pageCG else {
            outDoc.insert(page, at: outDoc.pageCount)
            continue
        }
        
        // Compute this page's pixel box from the normalized bounding box
        let pagePixelBox = CGRect(
            x: CGFloat(normX) * CGFloat(pW),
            y: CGFloat(normY) * CGFloat(pH),
            width: CGFloat(normW) * CGFloat(pW),
            height: CGFloat(normH) * CGFloat(pH)
        )
        
        // Analyze perimeter on this page to adapt to page-specific colors/gradients
        let pageBG = analyzePerimeterBackground(cgImage: pImage, box: pagePixelBox)
        
        // Execute healing in-memory
        if let healedCG = healPageImage(
            pageImage: pImage,
            targetBox: pagePixelBox,
            bgAnalysis: pageBG,
            mode: opts.healingMode,
            featherRadius: opts.featherRadius
        ) {
            let nsImg = NSImage(cgImage: healedCG, size: pageMedia.size)
            if let healedPage = PDFPage(image: nsImg) {
                outDoc.insert(healedPage, at: outDoc.pageCount)
                healedCount += 1
                if !opts.jsonOutput && (pageIdx % 5 == 0 || pageIdx == totalPages - 1) {
                    print("  ↳ Page \(pageIdx + 1)/\(totalPages) healed (\(pageBG.hex), grad: \(pageBG.isGradient))")
                }
                continue
            }
        }
        
        // Fallback to original page if healing failed
        outDoc.insert(page, at: outDoc.pageCount)
    }
    
    // Save Resulting PDF
    let outURL = URL(fileURLWithPath: opts.outputPath)
    let parentDir = outURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    
    let saved = outDoc.write(to: outURL)
    let elapsed = CFAbsoluteTimeGetCurrent() - startTime
    
    if saved {
        if opts.jsonOutput {
            let resultDict: [String: Any] = [
                "success": true,
                "input": opts.inputPath,
                "output": opts.outputPath,
                "totalPages": totalPages,
                "healedPages": healedCount,
                "elapsedSeconds": elapsed,
                "detection": [
                    "anchorPage": anchorIdx + 1,
                    "normalized": [normX, normY, normW, normH],
                    "matchedText": matchedTexts,
                    "anchorBG": anchorBG.hex
                ]
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: resultDict, options: .prettyPrinted),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                print(jsonStr)
            }
        } else {
            print(String(format: "✅ Successfully saved cleaned PDF to '%@' (%d pages healed in %.2fs)", outURL.lastPathComponent, healedCount, elapsed))
        }
    } else {
        fputs("Error: Failed to write output PDF to \(opts.outputPath)\n", stderr)
        exit(1)
    }
}

main()
