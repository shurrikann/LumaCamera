import UIKit

/// Public UIKit snapshotting preserves the compositor's glass; CALayer.render
/// does not. The non-key window stays offscreen and never covers the camera.
enum NativePhotoGlassRenderer {
    struct Patch { let image: UIImage; let sourceRect: CGRect }
    static func render(photo: UIImage, card: CGRect, cornerRadius: CGFloat) -> Patch? {
        guard #available(iOS 26.0, *) else { return nil }
        if Thread.isMainThread {
            return MainActor.assumeIsolated { snapshot(photo:photo,card:card,cornerRadius:cornerRadius) }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { snapshot(photo:photo,card:card,cornerRadius:cornerRadius) }
        }
    }

    @available(iOS 26.0, *) @MainActor
    private static func snapshot(photo: UIImage, card: CGRect, cornerRadius: CGFloat) -> Patch? {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              photo.size.width > 0,photo.size.height > 0 else { return nil }
        // Keep the material at normal control dimensions and snapshot only the
        // optical patch at device scale. The original photo stays at full size.
        let scale = min(photo.size.width,photo.size.height)/360
        let padding = scale*24
        let viewport = CGRect(x:0,y:max(0,card.minY-padding),width:photo.size.width,
            height:min(photo.size.height,card.maxY+padding)-max(0,card.minY-padding))
        let bounds = CGRect(origin:.zero,size:CGSize(width:viewport.width/scale,height:viewport.height/scale))
        let window = UIWindow(windowScene:scene)
        window.frame = CGRect(x:-20_000,y:0,width:bounds.width,height:bounds.height)
        window.windowLevel = .alert+1
        let host = UIViewController(); window.rootViewController = host
        host.view.frame = bounds; host.view.backgroundColor = .clear
        let image = UIImageView(image:photo)
        image.frame = CGRect(x:0,y:-viewport.minY/scale,width:photo.size.width/scale,height:photo.size.height/scale)
        image.contentMode = .scaleToFill
        host.view.addSubview(image)
        let effect = UIVisualEffectView(effect:UIGlassEffect(style:.clear))
        effect.frame = CGRect(x:card.minX/scale,y:(card.minY-viewport.minY)/scale,width:card.width/scale,height:card.height/scale)
        effect.layer.cornerRadius = cornerRadius/scale; effect.clipsToBounds = true
        host.view.addSubview(effect)
        window.isUserInteractionEnabled = false
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        window.layoutIfNeeded(); host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat(); format.scale = scene.screen.scale
        format.opaque = true; format.preferredRange = .standard
        var complete = false
        let snapshot = UIGraphicsImageRenderer(size:bounds.size,format:format).image { _ in
            complete = window.drawHierarchy(in:bounds,afterScreenUpdates:true)
        }
        guard complete,let cg = snapshot.cgImage else { return nil }
        return Patch(image:UIImage(cgImage:cg,scale:1,orientation:.up),sourceRect:viewport)
    }
}
