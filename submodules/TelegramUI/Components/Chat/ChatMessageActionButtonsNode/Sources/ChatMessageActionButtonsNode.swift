import Foundation
import UIKit
import AsyncDisplayKit
import TelegramCore
import Postbox
import Display
import TelegramPresentationData
import AccountContext
import WallpaperBackgroundNode
import UrlHandling
import SwiftSignalKit
import TextLoadingEffect

private let titleFont = Font.medium(16.0)

private extension UIBezierPath {
    convenience init(roundRect rect: CGRect, topLeftRadius: CGFloat = 0.0, topRightRadius: CGFloat = 0.0, bottomLeftRadius: CGFloat = 0.0, bottomRightRadius: CGFloat = 0.0) {
        self.init()

        let path = CGMutablePath()

        let topLeft = rect.origin
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)

        if topLeftRadius != .zero {
            path.move(to: CGPoint(x: topLeft.x+topLeftRadius, y: topLeft.y))
        } else {
            path.move(to: CGPoint(x: topLeft.x, y: topLeft.y))
        }

        if topRightRadius != .zero {
            path.addLine(to: CGPoint(x: topRight.x-topRightRadius, y: topRight.y))
            path.addCurve(to:  CGPoint(x: topRight.x, y: topRight.y+topRightRadius), control1: CGPoint(x: topRight.x, y: topRight.y), control2:CGPoint(x: topRight.x, y: topRight.y + topRightRadius))
        } else {
             path.addLine(to: CGPoint(x: topRight.x, y: topRight.y))
        }

        if bottomRightRadius != .zero {
            path.addLine(to: CGPoint(x: bottomRight.x, y: bottomRight.y-bottomRightRadius))
            path.addCurve(to: CGPoint(x: bottomRight.x-bottomRightRadius, y: bottomRight.y), control1: CGPoint(x: bottomRight.x, y: bottomRight.y), control2: CGPoint(x: bottomRight.x-bottomRightRadius, y: bottomRight.y))
        } else {
            path.addLine(to: CGPoint(x: bottomRight.x, y: bottomRight.y))
        }

        if bottomLeftRadius != .zero {
            path.addLine(to: CGPoint(x: bottomLeft.x+bottomLeftRadius, y: bottomLeft.y))
            path.addCurve(to: CGPoint(x: bottomLeft.x, y: bottomLeft.y-bottomLeftRadius), control1: CGPoint(x: bottomLeft.x, y: bottomLeft.y), control2: CGPoint(x: bottomLeft.x, y: bottomLeft.y-bottomLeftRadius))
        } else {
            path.addLine(to: CGPoint(x: bottomLeft.x, y: bottomLeft.y))
        }

        if topLeftRadius != .zero {
            path.addLine(to: CGPoint(x: topLeft.x, y: topLeft.y+topLeftRadius))
            path.addCurve(to: CGPoint(x: topLeft.x+topLeftRadius, y: topLeft.y) , control1: CGPoint(x: topLeft.x, y: topLeft.y) , control2: CGPoint(x: topLeft.x+topLeftRadius, y: topLeft.y))
        } else {
            path.addLine(to: CGPoint(x: topLeft.x, y: topLeft.y))
        }

        path.closeSubpath()
        self.cgPath = path
    }
}

private final class ChatMessageActionButtonNode: ASDisplayNode {
    private var backgroundBlurView: PortalView?
    
    private var titleNode: TextNode?
    private var iconNode: ASImageNode?
    private var buttonView: HighlightTrackingButton?
    
    private var wallpaperBackgroundNode: WallpaperBackgroundNode?
    private var backgroundContent: WallpaperBubbleBackgroundNode?
    private var backgroundColorNode: ASDisplayNode?
    
    private var maskPath: CGPath?
    private var loadingEffectView: TextLoadingEffectView?
    
    private var absolutePosition: (CGRect, CGSize)?
    
    private var button: ReplyMarkupButton?
    var pressed: ((ReplyMarkupButton, Promise<Bool>) -> Void)?
    var longTapped: ((ReplyMarkupButton) -> Void)?
    
    var longTapRecognizer: UILongPressGestureRecognizer?
    
    private let accessibilityArea: AccessibilityAreaNode
    
    private var progressDisposable: Disposable?
    
    override init() {
        self.accessibilityArea = AccessibilityAreaNode()
        self.accessibilityArea.accessibilityTraits = .button
        
        super.init()
        
        self.addSubnode(self.accessibilityArea)
        
        self.accessibilityArea.activate = { [weak self] in
            self?.buttonPressed()
            return true
        }
    }
    
    deinit {
        self.progressDisposable?.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        let buttonView = HighlightTrackingButton(frame: self.bounds)
        buttonView.addTarget(self, action: #selector(self.buttonPressed), for: [.touchUpInside])
        self.buttonView = buttonView
        buttonView.isAccessibilityElement = false
        self.view.addSubview(buttonView)
        buttonView.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    //strongSelf.backgroundBlurNode.layer.removeAnimation(forKey: "opacity")
                    //strongSelf.backgroundBlurNode.alpha = 0.55
                    
                    if let backgroundBlurView = strongSelf.backgroundBlurView {
                        backgroundBlurView.view.layer.removeAnimation(forKey: "opacity")
                        backgroundBlurView.view.alpha = 0.55
                    }
                    
                    strongSelf.backgroundContent?.layer.removeAnimation(forKey: "opacity")
                    strongSelf.backgroundContent?.alpha = 0.55
                } else {
                    //strongSelf.backgroundBlurNode.alpha = 1.0
                    //strongSelf.backgroundBlurNode.layer.animateAlpha(from: 0.55, to: 1.0, duration: 0.2)
                    
                    if let backgroundBlurView = strongSelf.backgroundBlurView {
                        backgroundBlurView.view.alpha = 1.0
                        backgroundBlurView.view.layer.animateAlpha(from: 0.55, to: 1.0, duration: 0.2)
                    }
                    
                    strongSelf.backgroundContent?.alpha = 1.0
                    strongSelf.backgroundContent?.layer.animateAlpha(from: 0.55, to: 1.0, duration: 0.2)
                }
            }
        }
        
        let longTapRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.longTapGesture(_:)))
        longTapRecognizer.minimumPressDuration = 0.3
        buttonView.addGestureRecognizer(longTapRecognizer)
        self.longTapRecognizer = longTapRecognizer
    }
    
    @objc func buttonPressed() {
        if let button = self.button, let pressed = self.pressed {
            let progressPromise = Promise<Bool>()
            pressed(button, progressPromise)
            
            self.progressDisposable?.dispose()
            self.progressDisposable = (progressPromise.get()
            |> deliverOnMainQueue).startStrict(next: { [weak self] isLoading in
                guard let self else {
                    return
                }
                self.updateIsLoading(isLoading: isLoading)
            })
        }
    }
    
    private func updateIsLoading(isLoading: Bool) {
        if isLoading {
            if self.loadingEffectView == nil {
                let loadingEffectView = TextLoadingEffectView(frame: CGRect())
                self.loadingEffectView = loadingEffectView
                
                if let iconNode = self.iconNode, iconNode.view.superview != nil {
                    self.view.insertSubview(loadingEffectView, belowSubview: iconNode.view)
                } else if let titleNode = self.titleNode, titleNode.view.superview != nil {
                    self.view.insertSubview(loadingEffectView, belowSubview: titleNode.view)
                } else {
                    self.view.addSubview(loadingEffectView)
                }
                
                if let buttonView = self.buttonView, let maskPath = self.maskPath {
                    let loadingFrame = buttonView.frame
                    
                    loadingEffectView.frame = loadingFrame
                    loadingEffectView.update(color: UIColor(white: 1.0, alpha: 1.0), rect: CGRect(origin: CGPoint(), size: loadingFrame.size), path: maskPath)
                }
            }
        } else {
            if let loadingEffectView {
                self.loadingEffectView = nil
                loadingEffectView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2, removeOnCompletion: false, completion: { [weak loadingEffectView] _ in
                    loadingEffectView?.removeFromSuperview()
                })
            }
        }
    }
    
    @objc func longTapGesture(_ recognizer: UILongPressGestureRecognizer) {
        if let button = self.button, let longTapped = self.longTapped, recognizer.state == .began {
            longTapped(button)
        }
    }
    
    func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) {
        self.absolutePosition = (rect, containerSize)
        
        if let backgroundContent = self.backgroundContent {
            var backgroundFrame = backgroundContent.frame
            backgroundFrame.origin.x += rect.minX
            backgroundFrame.origin.y += rect.minY
            backgroundContent.update(rect: backgroundFrame, within: containerSize, transition: .immediate)
        }
    }
    
    class func asyncLayout(_ maybeNode: ChatMessageActionButtonNode?) -> (_ context: AccountContext, _ theme: ChatPresentationThemeData, _ bubbleCorners: PresentationChatBubbleCorners, _ strings: PresentationStrings, _ backgroundNode: WallpaperBackgroundNode?, _ message: Message, _ button: ReplyMarkupButton, _ customInfo: ChatMessageActionButtonsNode.CustomInfo?, _ constrainedWidth: CGFloat, _ position: MessageBubbleActionButtonPosition) -> (minimumWidth: CGFloat, layout: ((CGFloat) -> (CGSize, (ListViewItemUpdateAnimation) -> ChatMessageActionButtonNode))) {
        let titleLayout = TextNode.asyncLayout(maybeNode?.titleNode)
        
        return { context, theme, bubbleCorners, strings, backgroundNode, message, button, customInfo, constrainedWidth, position in
            let incoming = message.effectivelyIncoming(context.account.peerId)
            let graphics = PresentationResourcesChat.additionalGraphics(theme.theme, wallpaper: theme.wallpaper, bubbleCorners: bubbleCorners)
            
            let messageTheme = incoming ? theme.theme.chat.message.incoming : theme.theme.chat.message.outgoing
            
            let titleColor = bubbleVariableColor(variableColor: messageTheme.actionButtonsTextColor, wallpaper: theme.wallpaper)
            
            var isStarsPayment = false
            let iconImage: UIImage?
            var tintColor: UIColor?
            if let customIcon = customInfo?.icon {
                switch customIcon {
                case .suggestedPostReject:
                    iconImage = PresentationResourcesChat.messageButtonsPostReject(theme.theme)
                case .suggestedPostApprove:
                    iconImage = PresentationResourcesChat.messageButtonsPostApprove(theme.theme)
                case .suggestedPostEdit:
                    iconImage = PresentationResourcesChat.messageButtonsPostEdit(theme.theme)
                }
                tintColor = titleColor
            } else {
                switch button.action {
                case .text:
                    iconImage = incoming ? graphics.chatBubbleActionButtonIncomingMessageIconImage : graphics.chatBubbleActionButtonOutgoingMessageIconImage
                case let .url(value):
                    var isApp = false
                    if isTelegramMeLink(value), let internalUrl = parseFullInternalUrl(sharedContext: context.sharedContext, context: context, url: value) {
                        if case .peer(_, .appStart) = internalUrl {
                            isApp = true
                        } else if case .peer(_, .attachBotStart) = internalUrl {
                            isApp = true
                        } else if case .startAttach = internalUrl {
                            isApp = true
                        }
                    }
                    if isApp {
                        iconImage = incoming ? graphics.chatBubbleActionButtonIncomingWebAppIconImage : graphics.chatBubbleActionButtonOutgoingWebAppIconImage
                    } else if value.lowercased().contains("?startgroup=") {
                        iconImage = incoming ? graphics.chatBubbleActionButtonIncomingAddToChatIconImage : graphics.chatBubbleActionButtonOutgoingAddToChatIconImage
                    } else {
                        iconImage = incoming ? graphics.chatBubbleActionButtonIncomingLinkIconImage : graphics.chatBubbleActionButtonOutgoingLinkIconImage
                    }
                case .urlAuth:
                    iconImage = incoming ? graphics.chatBubbleActionButtonIncomingLinkIconImage : graphics.chatBubbleActionButtonOutgoingLinkIconImage
                case .requestPhone:
                    iconImage = incoming ? graphics.chatBubbleActionButtonIncomingPhoneIconImage : graphics.chatBubbleActionButtonOutgoingPhoneIconImage
                case .requestMap:
                    iconImage = incoming ? graphics.chatBubbleActionButtonIncomingLocationIconImage : graphics.chatBubbleActionButtonOutgoingLocationIconImage
                case .switchInline:
                    iconImage = incoming ? graphics.chatBubbleActionButtonIncomingShareIconImage : graphics.chatBubbleActionButtonOutgoingShareIconImage
                case .payment:
                    if button.title.contains("⭐️") {
                        isStarsPayment = true
                        iconImage = nil
                    } else {
                        iconImage = incoming ? graphics.chatBubbleActionButtonIncomingPaymentIconImage : graphics.chatBubbleActionButtonOutgoingPaymentIconImage
                    }
                case .openUserProfile:
                    iconImage = incoming ? graphics.chatBubbleActionButtonIncomingProfileIconImage : graphics.chatBubbleActionButtonOutgoingProfileIconImage
                case .openWebView:
                    iconImage = incoming ? graphics.chatBubbleActionButtonIncomingWebAppIconImage : graphics.chatBubbleActionButtonOutgoingWebAppIconImage
                case .copyText:
                    iconImage = incoming ? graphics.chatBubbleActionButtonIncomingCopyIconImage : graphics.chatBubbleActionButtonOutgoingCopyIconImage
                default:
                    iconImage = nil
                }
            }
            
            let sideInset: CGFloat = 8.0
            let minimumSideInset: CGFloat = 4.0 + (iconImage?.size.width ?? 0.0)
            
            var title = button.title
            if case .payment = button.action {
                for media in message.media {
                    if let invoice = media as? TelegramMediaInvoice {
                        if invoice.receiptMessageId != nil {
                            title = strings.Message_ReplyActionButtonShowReceipt
                        }
                    }
                }
            }
            
            let attributedTitle: NSAttributedString
            if isStarsPayment {
                let updatedTitle = title.replacingOccurrences(of: "⭐️", with: " # ")
                let buttonAttributedString = NSMutableAttributedString(string: updatedTitle, font: titleFont, textColor: titleColor, paragraphAlignment: .center)
                if let range = buttonAttributedString.string.range(of: "#"), let starImage = UIImage(bundleImageName: "Item List/PremiumIcon") {
                    buttonAttributedString.addAttribute(.attachment, value: starImage, range: NSRange(range, in: buttonAttributedString.string))
                    buttonAttributedString.addAttribute(.foregroundColor, value: titleColor, range: NSRange(range, in: buttonAttributedString.string))
                    buttonAttributedString.addAttribute(.baselineOffset, value: 1.0, range: NSRange(range, in: buttonAttributedString.string))
                }
                attributedTitle = buttonAttributedString
            } else {
                attributedTitle = NSAttributedString(string: title, font: titleFont, textColor: titleColor)
            }
            
            var customIconSpaceWidth: CGFloat = 0.0
            if let iconImage, customInfo?.icon != nil {
                customIconSpaceWidth = 3.0 + iconImage.size.width
            }
            
            let (titleSize, titleApply) = titleLayout(TextNodeLayoutArguments(attributedString: attributedTitle, backgroundColor: nil, maximumNumberOfLines: 1, truncationType: .end, constrainedSize: CGSize(width: max(44.0, constrainedWidth - minimumSideInset - minimumSideInset - customIconSpaceWidth), height: CGFloat.greatestFiniteMagnitude), alignment: .center, cutout: nil, insets: UIEdgeInsets(top: 1.0, left: 0.0, bottom: 1.0, right: 0.0)))
            let contentWidth = titleSize.size.width + sideInset + sideInset + customIconSpaceWidth

            return (contentWidth, { width in
                return (CGSize(width: width, height: 42.0), { animation in
                    var animation = animation
                    
                    let node: ChatMessageActionButtonNode
                    if let maybeNode = maybeNode {
                        node = maybeNode
                    } else {
                        node = ChatMessageActionButtonNode()
                        animation = .None
                    }
                    
                    node.wallpaperBackgroundNode = backgroundNode
                    node.button = button
                    
                    switch button.action {
                    case .url:
                        node.longTapRecognizer?.isEnabled = true
                    default:
                        node.longTapRecognizer?.isEnabled = false
                    }
                    
                    //animation.animator.updateFrame(layer: node.backgroundBlurNode.layer, frame: CGRect(origin: CGPoint(), size: CGSize(width: max(0.0, width), height: 42.0)), completion: nil)
                    
                    if node.backgroundBlurView == nil {
                        if let backgroundBlurView = backgroundNode?.makeFreeBackground() {
                            node.backgroundBlurView = backgroundBlurView
                            node.view.insertSubview(backgroundBlurView.view, at: 0)
                        }
                    }
                    if let backgroundBlurView = node.backgroundBlurView {
                        animation.animator.updateFrame(layer: backgroundBlurView.view.layer, frame: CGRect(origin: CGPoint(), size: CGSize(width: max(0.0, width), height: 42.0)), completion: nil)
                    }
                    
                    /*node.backgroundBlurNode.update(size: node.backgroundBlurNode.bounds.size, cornerRadius: 0.0, animator: animation.animator)
                    node.backgroundBlurNode.updateColor(color: selectDateFillStaticColor(theme: theme.theme, wallpaper: theme.wallpaper), enableBlur: context.sharedContext.energyUsageSettings.fullTranslucency && dateFillNeedsBlur(theme: theme.theme, wallpaper: theme.wallpaper), transition: .immediate)*/
                    
                    if backgroundNode?.hasExtraBubbleBackground() == true {
                        if node.backgroundContent == nil, let backgroundContent = backgroundNode?.makeBubbleBackground(for: .free) {
                            backgroundContent.clipsToBounds = true
                            backgroundContent.allowsGroupOpacity = true

                            node.backgroundContent = backgroundContent
                            node.insertSubnode(backgroundContent, at: 0)
                            
                            let backgroundColorNode = ASDisplayNode()
                            backgroundColorNode.backgroundColor = UIColor(rgb: 0xffffff, alpha: 0.08)
                            backgroundContent.addSubnode(backgroundColorNode)
                            node.backgroundColorNode = backgroundColorNode
                        }
                    } else {
                        node.backgroundContent?.removeFromSupernode()
                        node.backgroundContent = nil
                        
                        node.backgroundColorNode?.removeFromSupernode()
                        node.backgroundColorNode = nil
                    }
                    
                    node.cornerRadius = bubbleCorners.auxiliaryRadius
                    node.clipsToBounds = true
                    
                    if let backgroundContent = node.backgroundContent {
                        //node.backgroundBlurNode.isHidden = true
                        node.backgroundBlurView?.view.isHidden = true
                        backgroundContent.frame = CGRect(origin: CGPoint(), size: CGSize(width: max(0.0, width), height: 42.0))
                        
                        node.backgroundColorNode?.frame = backgroundContent.bounds
                        
                        if let (rect, containerSize) = node.absolutePosition {
                            var backgroundFrame = backgroundContent.frame
                            backgroundFrame.origin.x += rect.minX
                            backgroundFrame.origin.y += rect.minY
                            backgroundContent.update(rect: backgroundFrame, within: containerSize, transition: .immediate)
                        }
                    } else {
                        node.backgroundBlurView?.view.isHidden = false
                    }
                    
                    
                    let rect = CGRect(origin: CGPoint(), size: CGSize(width: max(0.0, width), height: 42.0))
                    let maskPath: CGPath?
                    var needsMask = true
                    switch position {
                        case .bottomSingle:
                            maskPath = UIBezierPath(roundRect: rect, topLeftRadius: bubbleCorners.auxiliaryRadius, topRightRadius: bubbleCorners.auxiliaryRadius, bottomLeftRadius: bubbleCorners.mainRadius, bottomRightRadius: bubbleCorners.mainRadius).cgPath
                        case .bottomLeft:
                            maskPath = UIBezierPath(roundRect: rect, topLeftRadius: bubbleCorners.auxiliaryRadius, topRightRadius: bubbleCorners.auxiliaryRadius, bottomLeftRadius: bubbleCorners.mainRadius, bottomRightRadius: bubbleCorners.auxiliaryRadius).cgPath
                        case .bottomRight:
                            maskPath = UIBezierPath(roundRect: rect, topLeftRadius: bubbleCorners.auxiliaryRadius, topRightRadius: bubbleCorners.auxiliaryRadius, bottomLeftRadius: bubbleCorners.auxiliaryRadius, bottomRightRadius: bubbleCorners.mainRadius).cgPath
                        default:
                            needsMask = false
                            maskPath = UIBezierPath(roundRect: rect, topLeftRadius: bubbleCorners.auxiliaryRadius, topRightRadius: bubbleCorners.auxiliaryRadius, bottomLeftRadius: bubbleCorners.auxiliaryRadius, bottomRightRadius: bubbleCorners.auxiliaryRadius).cgPath
                    }
                    
                    let currentMaskPath = (node.layer.mask as? CAShapeLayer)?.path
                    node.maskPath = maskPath
                    
                    let effectiveMaskPath = needsMask ? maskPath : nil
                    
                    if currentMaskPath != effectiveMaskPath {
                        if let effectiveMaskPath = effectiveMaskPath {
                            let shapeLayer = CAShapeLayer()
                            shapeLayer.path = effectiveMaskPath
                            node.layer.mask = shapeLayer
                        } else {
                            node.layer.mask = nil
                        }
                    }
                                        
                    if iconImage != nil {
                        if node.iconNode == nil {
                            let iconNode = ASImageNode()
                            iconNode.contentMode = .center
                            node.iconNode = iconNode
                            node.addSubnode(iconNode)
                        }
                        node.iconNode?.image = iconImage
                        node.iconNode?.customTintColor = tintColor
                    } else if node.iconNode != nil {
                        node.iconNode?.removeFromSupernode()
                        node.iconNode = nil
                    }
                    
                    let titleNode = titleApply()
                    if node.titleNode !== titleNode {
                        node.titleNode = titleNode
                        node.addSubnode(titleNode)
                        titleNode.isUserInteractionEnabled = false
                    }
                    
                    var titleFrame = CGRect(origin: CGPoint(x: floor((width - titleSize.size.width) / 2.0), y: floor((42.0 - titleSize.size.height) / 2.0) + 1.0), size: titleSize.size)
                    if let image = node.iconNode?.image, customInfo?.icon != nil {
                        titleFrame.origin.x = floorToScreenPixels((width - titleSize.size.width - image.size.width - 3.0) * 0.5) + 3.0 + image.size.width
                    }
                    titleNode.layer.bounds = CGRect(origin: CGPoint(), size: titleFrame.size)
                    animation.animator.updatePosition(layer: titleNode.layer, position: CGPoint(x: titleFrame.midX, y: titleFrame.midY), completion: nil)
                    
                    if let buttonView = node.buttonView {
                        buttonView.frame = CGRect(origin: CGPoint(), size: CGSize(width: width, height: 42.0))
                    }
                    if let iconNode = node.iconNode {
                        let iconFrame: CGRect
                        if customInfo?.icon != nil, let image = iconNode.image {
                            iconFrame = CGRect(x: titleFrame.minX - 3.0 - image.size.width, y: titleFrame.minY + floorToScreenPixels((titleFrame.height - image.size.height) * 0.5) - 1.0, width: image.size.width, height: image.size.height)
                        } else {
                            iconFrame = CGRect(x: width - 16.0, y: 4.0, width: 12.0, height: 12.0)
                        }
                        animation.animator.updateFrame(layer: iconNode.layer, frame: iconFrame, completion: nil)
                    }
                    
                    if let (rect, size) = node.absolutePosition {
                        node.updateAbsoluteRect(rect, within: size)
                    }
                    
                    node.accessibilityArea.accessibilityLabel = title
                    node.accessibilityArea.frame = CGRect(origin: CGPoint(), size: CGSize(width: width, height: 42.0))
                    
                    if let buttonView = node.buttonView {
                        let isEnabled = customInfo?.isEnabled ?? true
                        if buttonView.isEnabled != isEnabled {
                            buttonView.isEnabled = isEnabled
                            
                            if let backgroundBlurView = node.backgroundBlurView {
                                backgroundBlurView.view.alpha = isEnabled ? 1.0 : 0.55
                            }
                            node.backgroundContent?.alpha = isEnabled ? 1.0 : 0.55
                        }
                    }
                    
                    return node
                })
            })
        }
    }
}

public final class ChatMessageActionButtonsNode: ASDisplayNode {
    public enum CustomIcon {
        case suggestedPostApprove
        case suggestedPostReject
        case suggestedPostEdit
    }
    
    public struct CustomInfo {
        var isEnabled: Bool
        var icon: CustomIcon?
        
        public init(isEnabled: Bool, icon: CustomIcon?) {
            self.isEnabled = isEnabled
            self.icon = icon
        }
    }
    
    private var buttonNodes: [ChatMessageActionButtonNode] = []
    
    private var buttonPressedWrapper: ((ReplyMarkupButton, Promise<Bool>) -> Void)?
    private var buttonLongTappedWrapper: ((ReplyMarkupButton) -> Void)?
    public var buttonPressed: ((ReplyMarkupButton, Promise<Bool>) -> Void)?
    public var buttonLongTapped: ((ReplyMarkupButton) -> Void)?
    
    private var absolutePosition: (CGRect, CGSize)?
    
    override public init() {
        super.init()
        
        self.buttonPressedWrapper = { [weak self] button, promise in
            if let buttonPressed = self?.buttonPressed {
                buttonPressed(button, promise)
            }
        }
        
        self.buttonLongTappedWrapper = { [weak self] button in
            if let buttonLongTapped = self?.buttonLongTapped {
                buttonLongTapped(button)
            }
        }
    }
    
    public func updateAbsoluteRect(_ rect: CGRect, within containerSize: CGSize) {
        self.absolutePosition = (rect, containerSize)
        
        for button in self.buttonNodes {
            var buttonFrame = button.frame
            buttonFrame.origin.x += rect.minX
            buttonFrame.origin.y += rect.minY
            button.updateAbsoluteRect(buttonFrame, within: containerSize)
        }
    }
    
    public class func asyncLayout(_ maybeNode: ChatMessageActionButtonsNode?) -> (_ context: AccountContext, _ theme: ChatPresentationThemeData, _ chatBubbleCorners: PresentationChatBubbleCorners, _ strings: PresentationStrings, _ backgroundNode: WallpaperBackgroundNode?, _ replyMarkup: ReplyMarkupMessageAttribute, _ customInfos: [MemoryBuffer: CustomInfo], _ message: Message, _ constrainedWidth: CGFloat) -> (minWidth: CGFloat, layout: (CGFloat) -> (CGSize, (_ animation: ListViewItemUpdateAnimation) -> ChatMessageActionButtonsNode)) {
        let currentButtonLayouts = maybeNode?.buttonNodes.map { ChatMessageActionButtonNode.asyncLayout($0) } ?? []
        
        return { context, theme, chatBubbleCorners, strings, backgroundNode, replyMarkup, customInfos, message, constrainedWidth in
            let buttonHeight: CGFloat = 42.0
            let buttonSpacing: CGFloat = 2.0
            
            var overallMinimumRowWidth: CGFloat = 0.0
            
            var finalizeRowLayouts: [[((CGFloat) -> (CGSize, (ListViewItemUpdateAnimation) -> ChatMessageActionButtonNode))]] = []
            
            var rowIndex = 0
            var buttonIndex = 0
            for row in replyMarkup.rows {
                var maximumRowButtonWidth: CGFloat = 0.0
                let maximumButtonWidth: CGFloat = max(1.0, floor((constrainedWidth - CGFloat(max(0, row.buttons.count - 1)) * buttonSpacing) / CGFloat(row.buttons.count)))
                var finalizeRowButtonLayouts: [((CGFloat) -> (CGSize, (ListViewItemUpdateAnimation) -> ChatMessageActionButtonNode))] = []
                var rowButtonIndex = 0
                for button in row.buttons {
                    var customInfo: CustomInfo?
                    if case let .callback(_, data) = button.action {
                        customInfo = customInfos[data]
                    }
                    
                    let buttonPosition: MessageBubbleActionButtonPosition
                    if rowIndex == replyMarkup.rows.count - 1 {
                        if row.buttons.count == 1 {
                            buttonPosition = .bottomSingle
                        } else if rowButtonIndex == 0 {
                            buttonPosition = .bottomLeft
                        } else if rowButtonIndex == row.buttons.count - 1 {
                            buttonPosition = .bottomRight
                        } else {
                            buttonPosition = .middle
                        }
                    } else {
                        buttonPosition = .middle
                    }
                    
                    let prepareButtonLayout: (minimumWidth: CGFloat, layout: ((CGFloat) -> (CGSize, (ListViewItemUpdateAnimation) -> ChatMessageActionButtonNode)))
                    if buttonIndex < currentButtonLayouts.count {
                        prepareButtonLayout = currentButtonLayouts[buttonIndex](context, theme, chatBubbleCorners, strings, backgroundNode, message, button, customInfo, maximumButtonWidth, buttonPosition)
                    } else {
                        prepareButtonLayout = ChatMessageActionButtonNode.asyncLayout(nil)(context, theme, chatBubbleCorners, strings, backgroundNode, message, button, customInfo, maximumButtonWidth, buttonPosition)
                    }
                    
                    maximumRowButtonWidth = max(maximumRowButtonWidth, prepareButtonLayout.minimumWidth)
                    finalizeRowButtonLayouts.append(prepareButtonLayout.layout)
                    
                    buttonIndex += 1
                    rowButtonIndex += 1
                }
                
                overallMinimumRowWidth = max(overallMinimumRowWidth, maximumRowButtonWidth * CGFloat(row.buttons.count) + buttonSpacing * max(0.0, CGFloat(row.buttons.count - 1)))
                finalizeRowLayouts.append(finalizeRowButtonLayouts)
                
                rowIndex += 1
            }
            
            return (min(constrainedWidth, overallMinimumRowWidth), { constrainedWidth in
                var buttonFramesAndApply: [(CGRect, (ListViewItemUpdateAnimation) -> ChatMessageActionButtonNode)] = []
                
                var verticalRowOffset: CGFloat = 0.0
                verticalRowOffset += buttonSpacing * 0.5
                
                var rowIndex = 0
                for finalizeRowButtonLayouts in finalizeRowLayouts {
                    let actualButtonWidth: CGFloat = max(1.0, floor((constrainedWidth - CGFloat(max(0, finalizeRowButtonLayouts.count - 1)) * buttonSpacing) / CGFloat(finalizeRowButtonLayouts.count)))
                    var horizontalButtonOffset: CGFloat = 0.0
                    for finalizeButtonLayout in finalizeRowButtonLayouts {
                        let (buttonSize, buttonApply) = finalizeButtonLayout(actualButtonWidth)
                        let buttonFrame = CGRect(origin: CGPoint(x: horizontalButtonOffset, y: verticalRowOffset), size: buttonSize)
                        buttonFramesAndApply.append((buttonFrame, buttonApply))
                        horizontalButtonOffset += buttonSize.width + buttonSpacing
                    }
                    
                    verticalRowOffset += buttonHeight + buttonSpacing
                    rowIndex += 1
                }
                if verticalRowOffset > 0.0 {
                    verticalRowOffset = max(0.0, verticalRowOffset - buttonSpacing)
                }
                
                return (CGSize(width: constrainedWidth, height: verticalRowOffset), { animation in
                    let node: ChatMessageActionButtonsNode
                    if let maybeNode = maybeNode {
                        node = maybeNode
                    } else {
                        node = ChatMessageActionButtonsNode()
                    }
                    
                    var updatedButtons: [ChatMessageActionButtonNode] = []
                    var index = 0
                    for (buttonFrame, buttonApply) in buttonFramesAndApply {
                        let buttonNode = buttonApply(animation)
                        updatedButtons.append(buttonNode)
                        if buttonNode.supernode == nil {
                            buttonNode.pressed = node.buttonPressedWrapper
                            buttonNode.longTapped = node.buttonLongTappedWrapper
                            buttonNode.frame = buttonFrame
                            
                            node.addSubnode(buttonNode)
                        } else {
                            animation.animator.updateFrame(layer: buttonNode.layer, frame: buttonFrame, completion: nil)
                        }
                        index += 1
                    }
                    
                    var buttonsUpdated = false
                    if node.buttonNodes.count != updatedButtons.count {
                        buttonsUpdated = true
                    } else {
                        for i in 0 ..< updatedButtons.count {
                            if updatedButtons[i] !== node.buttonNodes[i] {
                                buttonsUpdated = true
                                break
                            }
                        }
                    }
                    if buttonsUpdated {
                        for currentButton in node.buttonNodes {
                            if !updatedButtons.contains(currentButton) {
                                currentButton.removeFromSupernode()
                            }
                        }
                    }
                    node.buttonNodes = updatedButtons
                    
                    if let (rect, size) = node.absolutePosition {
                        node.updateAbsoluteRect(rect, within: size)
                    }
                    
                    return node
                })
            })
        }
    }
}
