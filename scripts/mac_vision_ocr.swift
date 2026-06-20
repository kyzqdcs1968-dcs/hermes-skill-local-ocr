// mac_vision_ocr.swift
// macOS Vision OCR — no external dependencies
// Usage: mac_vision_ocr <file> --output-dir <dir> [--dpi N] [--language zh-Hans,en-US]
// Produces: <dir>/<basename>.md  and  <dir>/<basename>.pdfa.pdf

import Foundation
import Vision
import PDFKit
import AppKit
import ImageIO
import CoreText
import CoreGraphics

// MARK: - Types

struct Block {
    let text: String
    let confidence: Float
    let x, y, w, h: CGFloat  // image pixel coords, top-left origin
}

struct Page {
    let index: Int
    let imgWidth, imgHeight: Int
    let blocks: [Block]
}

// MARK: - Argument Parsing

var inputPath = ""
var outputDir = "."
var dpi: CGFloat = 220
var languages = ["zh-Hans", "zh-Hant", "en-US"]

var ai = 1
let argv = CommandLine.arguments
while ai < argv.count {
    switch argv[ai] {
    case "--output-dir":
        ai += 1; if ai < argv.count { outputDir = argv[ai] }
    case "--dpi":
        ai += 1; if ai < argv.count { dpi = CGFloat(Double(argv[ai]) ?? 220) }
    case "--language":
        ai += 1; if ai < argv.count { languages = argv[ai].components(separatedBy: ",") }
    default:
        if !argv[ai].hasPrefix("-") { inputPath = argv[ai] }
    }
    ai += 1
}

guard !inputPath.isEmpty else {
    fputs("Usage: mac_vision_ocr <file> --output-dir <dir> [--dpi N]\n", stderr)
    exit(1)
}

let srcURL = URL(fileURLWithPath: (inputPath as NSString).standardizingPath)
let baseName = srcURL.deletingPathExtension().lastPathComponent
let srcExt = srcURL.pathExtension.lowercased()

try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

// MARK: - OCR

func ocrCGImage(_ cg: CGImage) -> [Block] {
    var blocks = [Block]()
    let request = VNRecognizeTextRequest { req, _ in
        guard let obs = req.results as? [VNRecognizedTextObservation] else { return }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        for o in obs {
            guard let top = o.topCandidates(1).first, !top.string.isEmpty else { continue }
            let bb = o.boundingBox  // normalized, bottom-left origin
            blocks.append(Block(
                text: top.string,
                confidence: top.confidence,
                x: bb.minX * W,
                y: (1.0 - bb.maxY) * H,
                w: bb.width * W,
                h: bb.height * H
            ))
        }
    }
    request.recognitionLanguages = languages
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([request])
    return blocks
}

// MARK: - Load Image

func loadCGImage(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

// MARK: - Render PDF Page to Bitmap (via PDFPage.thumbnail — handles rotation correctly)

func renderPDFPage(_ page: PDFPage) -> CGImage? {
    let b = page.bounds(for: .cropBox)
    let rot = page.rotation  // 0, 90, 180, 270
    let scale = dpi / 72.0
    let (w, h): (CGFloat, CGFloat) = (rot == 90 || rot == 270)
        ? (b.height * scale, b.width * scale)
        : (b.width * scale, b.height * scale)
    let size = CGSize(width: ceil(w), height: ceil(h))
    guard size.width > 0, size.height > 0 else { return nil }
    let nsImg = page.thumbnail(of: size, for: .cropBox)
    var rect = CGRect(origin: .zero, size: nsImg.size)
    return nsImg.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

// MARK: - Sort Blocks (top-to-bottom, left-to-right)

func sortedBlocks(_ page: Page) -> [Block] {
    let rowH = max(CGFloat(page.imgHeight) / 60.0, 10.0)
    return page.blocks.sorted {
        let rA = Int($0.y / rowH), rB = Int($1.y / rowH)
        return rA != rB ? rA < rB : $0.x < $1.x
    }
}

// MARK: - Process Input

var pages = [Page]()

if srcExt == "pdf" {
    guard let pdf = PDFDocument(url: srcURL) else {
        fputs("Cannot open PDF: \(inputPath)\n", stderr); exit(1)
    }
    let total = pdf.pageCount
    for idx in 0..<total {
        guard let pg = pdf.page(at: idx), let cg = renderPDFPage(pg) else {
            fputs("Warning: skipping page \(idx + 1)\n", stderr); continue
        }
        let blocks = ocrCGImage(cg)
        pages.append(Page(index: idx, imgWidth: cg.width, imgHeight: cg.height, blocks: blocks))
        fputs("Page \(idx + 1)/\(total): \(blocks.count) blocks\n", stderr)
    }
} else {
    guard let cg = loadCGImage(srcURL) else {
        fputs("Cannot open image: \(inputPath)\n", stderr); exit(1)
    }
    let blocks = ocrCGImage(cg)
    pages.append(Page(index: 0, imgWidth: cg.width, imgHeight: cg.height, blocks: blocks))
    fputs("Image: \(blocks.count) blocks\n", stderr)
}

guard !pages.isEmpty else {
    fputs("No pages to process\n", stderr); exit(1)
}

// MARK: - Write Markdown

var mdParts = [String]()
for (pi, page) in pages.enumerated() {
    if pages.count > 1 {
        mdParts.append("\n## 第 \(pi + 1) 页\n")
    }
    mdParts.append(contentsOf: sortedBlocks(page).map { $0.text })
}
let mdContent = mdParts.joined(separator: "\n")
let mdPath = "\(outputDir)/\(baseName).md"
try! mdContent.write(toFile: mdPath, atomically: true, encoding: .utf8)
fputs("Markdown → \(mdPath)\n", stderr)

// MARK: - Write Searchable Text PDF

let pdfPath = "\(outputDir)/\(baseName).pdfa.pdf"
let pdfData = NSMutableData()

// A4 page: 595 × 842 pt
var pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
let margin: CGFloat = 50
let lineH: CGFloat = 20

guard let consumer = CGDataConsumer(data: pdfData),
      let pdfCtx = CGContext(consumer: consumer, mediaBox: &pageRect, nil) else {
    fputs("Cannot create PDF context\n", stderr); exit(1)
}

// Fonts — PingFang SC handles Simplified & Traditional Chinese
let bodyFont = CTFontCreateWithName("PingFangSC-Regular" as CFString, 12, nil)
let sepFont  = CTFontCreateWithName("PingFangSC-Light"   as CFString,  9, nil)
let blackColor = CGColor(gray: 0,    alpha: 1)
let grayColor  = CGColor(gray: 0.55, alpha: 1)

var curY = pageRect.height - margin

func newPDFPage() {
    pdfCtx.beginPDFPage(nil)
    pdfCtx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    pdfCtx.fill(pageRect)
}

func drawLine(_ text: String, font: CTFont, color: CGColor) {
    if curY < margin {
        pdfCtx.endPDFPage()
        newPDFPage()
        curY = pageRect.height - margin
    }
    let aStr = CFAttributedStringCreate(nil, text as CFString, [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color
    ] as CFDictionary)!
    let line = CTLineCreateWithAttributedString(aStr)
    let bounds = CTLineGetBoundsWithOptions(line, [])
    let availW = pageRect.width - 2 * margin
    pdfCtx.textPosition = CGPoint(x: margin, y: curY)
    if bounds.width > availW && bounds.width > 0 {
        pdfCtx.saveGState()
        pdfCtx.scaleBy(x: availW / bounds.width, y: 1)
        CTLineDraw(line, pdfCtx)
        pdfCtx.restoreGState()
    } else {
        CTLineDraw(line, pdfCtx)
    }
    curY -= lineH
}

newPDFPage()

for (pi, page) in pages.enumerated() {
    if pages.count > 1 {
        drawLine("─── 第 \(pi + 1) 页 ───", font: sepFont, color: grayColor)
        curY -= lineH * 0.4
    }
    for blk in sortedBlocks(page) {
        drawLine(blk.text, font: bodyFont, color: blackColor)
    }
    if pi < pages.count - 1 { curY -= lineH }
}

pdfCtx.endPDFPage()
pdfCtx.closePDF()

try! (pdfData as Data).write(to: URL(fileURLWithPath: pdfPath))
fputs("PDF     → \(pdfPath)\n", stderr)
fputs("Done.\n", stderr)
