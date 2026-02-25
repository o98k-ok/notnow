#!/usr/bin/env swift
// Apple 规范：1024 图标内容应在中心 824x824，四周留 100px 透明边距，避免系统圆角裁切时出现白边
// Ref: https://developer.apple.com/design/human-interface-guidelines/app-icons

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let path = CommandLine.arguments.dropFirst().first ?? ""
guard !path.isEmpty else {
    fputs("Usage: icon_add_margin.swift <path-to-Icon-1024.png>\n", stderr)
    exit(1)
}

guard let img = NSImage(contentsOfFile: path) else {
    fputs("Failed to load image\n", stderr)
    exit(1)
}

let size: CGFloat = 1024
let margin: CGFloat = 100
let contentSize = size - margin * 2  // 824

guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

// 透明背景（不画任何东西，默认透明）
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// 将原图缩放到 824x824 并居中绘制
if let cgImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
    let contentRect = CGRect(x: margin, y: margin, width: contentSize, height: contentSize)
    ctx.draw(cgImage, in: contentRect)
}

guard let outImage = ctx.makeImage() else { exit(1) }

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, outImage, [:] as CFDictionary)
CGImageDestinationFinalize(dest)
print("Added 100px transparent margin (content 824x824); icon saved with alpha")
