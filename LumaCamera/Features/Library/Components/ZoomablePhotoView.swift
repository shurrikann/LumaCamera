import SwiftUI
import UIKit

/// Pinch changes the transform of one bounded preview; it never decodes RAW again.
struct ZoomablePhotoView: UIViewRepresentable {
    let image: UIImage
    var onSwipe: ((Int) -> Void)? = nil
    var onLivePress: ((Bool) -> Void)? = nil
    var pagingAngle = 0.0
    var preservesViewportOnImageUpdates = false
    func makeUIView(context: Context) -> PhotoZoomScrollView { PhotoZoomScrollView() }
    func updateUIView(_ view: PhotoZoomScrollView, context: Context) { if onLivePress == nil { view.endLivePress() }; view.updatePagingAngle(pagingAngle); view.onSwipe = onSwipe; view.onLivePress = onLivePress; view.display(image, preservingViewport: preservesViewportOnImageUpdates) }
    static func dismantleUIView(_ view: PhotoZoomScrollView, coordinator: ()) {
        view.endLivePress(); view.onLivePress = nil
        view.onSwipe = nil
        view.delegate = nil
        view.photoView.image = nil
    }
}

final class PhotoZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let photoView = UIImageView()
    var onSwipe: ((Int) -> Void)?
    private(set) var pagingAngle = 0.0
    var onLivePress: ((Bool) -> Void)?
    private var livePressActive = false
    private lazy var liveDelegate = PhotoLiveGestureDelegate(owner: self)
    var canPlayLive: Bool { zoomScale <= minimumZoomScale + 0.01 && onLivePress != nil }
    func beginLivePress() { guard canPlayLive else { return }; livePressActive = true; onLivePress?(true) }
    func endLivePress() { guard livePressActive else { return }; livePressActive = false; onLivePress?(false) }
    private lazy var pagingDelegate = PhotoPagingGestureDelegate(owner: self)
    private var lastBounds = CGSize.zero
    var canPage: Bool { !livePressActive && zoomScale <= minimumZoomScale + 0.01 && onSwipe != nil }
    func page(_ step: Int) { guard canPage else { return }; onSwipe?(step) }
    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        minimumZoomScale = 1; maximumZoomScale = 6
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        photoView.contentMode = .scaleAspectFit
        photoView.preferredImageDynamicRange = .high
        photoView.accessibilityLabel = "照片，可双指缩放"
        addSubview(photoView)
        let live = UILongPressGestureRecognizer(target: self, action: #selector(holdLive(_:)))
        live.minimumPressDuration = 0.25; live.allowableMovement = 12
        live.numberOfTouchesRequired = 1; live.delegate = liveDelegate
        addGestureRecognizer(live)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2; addGestureRecognizer(tap)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right, .up, .down] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipePhoto(_:)))
            swipe.direction = direction; swipe.numberOfTouchesRequired = 1
            swipe.delegate = pagingDelegate
            addGestureRecognizer(swipe)
            panGestureRecognizer.require(toFail: swipe)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updatePagingAngle(_ angle: Double) {
        guard pagingAngle != angle else { return }
        pagingAngle = angle
        endLivePress()
        setZoomScale(1, animated: false)
        lastBounds = .zero
        setNeedsLayout()
    }

    func display(_ image: UIImage, preservingViewport: Bool = false) {
        guard photoView.image !== image else { return }
        if preservingViewport, let previous = photoView.image,
           image.size.width > 0, image.size.height > 0, previous.size.width > 0, previous.size.height > 0,
           abs(image.size.width / image.size.height - previous.size.width / previous.size.height) < 0.0001,
           lastBounds == bounds.size, bounds.width > 0, bounds.height > 0 {
            // Colour/filter renders replace pixels, not the user's magnified viewport.
            photoView.image = image
            return
        }
        endLivePress()
        setZoomScale(1, animated: false)
        photoView.image = image
        lastBounds = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, let image = photoView.image,
              image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0 else { return }
        if lastBounds != bounds.size {
            lastBounds = bounds.size
            setZoomScale(1, animated: false)
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            photoView.frame = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
            contentSize = photoView.bounds.size
        }
        centerPhoto()
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { photoView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { if zoomScale > minimumZoomScale + 0.01 { endLivePress() }; centerPhoto() }
    private func centerPhoto() {
        contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2), left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
    }
    @objc private func holdLive(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began { beginLivePress() }
        else if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { endLivePress() }
    }
    @objc private func swipePhoto(_ gesture: UISwipeGestureRecognizer) {
        if let step = LibraryMediaRotation.pageStep(direction: gesture.direction, angle: pagingAngle) { page(step) }
    }
    @objc private func doubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1 { setZoomScale(1, animated: true); return }
        let point = gesture.location(in: photoView)
        zoom(to: CGRect(x: point.x - bounds.width / 6, y: point.y - bounds.height / 6, width: bounds.width / 3, height: bounds.height / 3), animated: true)
    }
}

/// Paging only participates at fit size; enlarged photos retain their one-finger pan.
private final class PhotoPagingGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var owner: PhotoZoomScrollView?
    init(owner: PhotoZoomScrollView) { self.owner = owner }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let owner, owner.canPage, let swipe = gestureRecognizer as? UISwipeGestureRecognizer else { return false }
        return LibraryMediaRotation.pageStep(direction: swipe.direction, angle: owner.pagingAngle) != nil
    }
}

private final class PhotoLiveGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var owner: PhotoZoomScrollView?
    init(owner: PhotoZoomScrollView) { self.owner = owner }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { owner?.canPlayLive == true }
}
