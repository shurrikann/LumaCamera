import CoreImage

/// Perspective-style stretch inside the crop frame. A positive horizontal
/// value narrows the top edge; a negative value narrows the bottom edge.
/// Vertical values narrow the left/right edge respectively. The resulting
/// trapezoid is mapped back to the full crop, so no blank edges are exposed.
struct PhotoStretch: Codable, Equatable {
    var horizontal = 0.0
    var vertical = 0.0

    var isIdentity: Bool {
        abs(horizontal) < 0.0001 && abs(vertical) < 0.0001
    }

    var clamped: Self {
        Self(horizontal: horizontal.isFinite ? min(max(horizontal, -0.5), 0.5) : 0,
             vertical: vertical.isFinite ? min(max(vertical, -0.5), 0.5) : 0)
    }

    func apply(to image: CIImage, referenceExtent: CGRect? = nil, preservesOutside: Bool = false) -> CIImage {
        let value = clamped
        guard !value.isIdentity else { return image }
        let extent = referenceExtent ?? image.extent
        guard extent.width > 1, extent.height > 1 else { return image }

        // 0.5 at the ±50% detent gives a strongly visible keystone while
        // keeping the quad convex and the crop fully filled.
        let topInset = max(0, value.horizontal) * 0.5
        let bottomInset = max(0, -value.horizontal) * 0.5
        let leftInset = max(0, value.vertical) * 0.5
        let rightInset = max(0, -value.vertical) * 0.5
        let topLeft = CGPoint(x: extent.minX + topInset * extent.width,
                              y: extent.maxY - leftInset * extent.height)
        let topRight = CGPoint(x: extent.maxX - topInset * extent.width,
                               y: extent.maxY - rightInset * extent.height)
        let bottomRight = CGPoint(x: extent.maxX - bottomInset * extent.width,
                                  y: extent.minY + rightInset * extent.height)
        let bottomLeft = CGPoint(x: extent.minX + bottomInset * extent.width,
                                 y: extent.minY + leftInset * extent.height)
        var parameters: [String: Any] = [
            kCIInputImageKey: image,
            "inputTopLeft": CIVector(cgPoint: topLeft),
            "inputTopRight": CIVector(cgPoint: topRight),
            "inputBottomRight": CIVector(cgPoint: bottomRight),
            "inputBottomLeft": CIVector(cgPoint: bottomLeft),
            "inputCrop": true
        ]
        guard let cropped = CIFilter(name: "CIPerspectiveCorrection", parameters: parameters)?.outputImage else { return image }
        parameters["inputCrop"] = !preservesOutside
        guard let output = preservesOutside ? CIFilter(name: "CIPerspectiveCorrection", parameters: parameters)?.outputImage : cropped else { return image }
        let outputExtent = cropped.extent
        guard outputExtent.width > 1, outputExtent.height > 1 else { return image }
        let transformed = output
            .transformed(by: CGAffineTransform(translationX: -outputExtent.minX, y: -outputExtent.minY))
            .transformed(by: CGAffineTransform(scaleX: extent.width / outputExtent.width,
                                               y: extent.height / outputExtent.height))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return preservesOutside ? transformed : transformed.cropped(to: extent)
    }
}
