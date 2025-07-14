import Foundation
import UIKit
import AsyncDisplayKit
import Postbox
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import SearchBarNode

private let searchBarFont = Font.regular(14.0)

class NotificationSearchItem: ListViewItem, ItemListItem {
    let selectable: Bool = false
    
    var sectionId: ItemListSectionId {
        return 0
    }
    var tag: ItemListItemTag? {
        return nil
    }
    var requestsNoInset: Bool {
        return true
    }
    
    let theme: PresentationTheme
    let isEnabled: Bool
    private let placeholder: String
    private let activate: () -> Void
    
    init(theme: PresentationTheme, isEnabled: Bool = true, placeholder: String, activate: @escaping () -> Void) {
        self.theme = theme
        self.isEnabled = isEnabled
        self.placeholder = placeholder
        self.activate = activate
    }
    
    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = NotificationSearchItemNode()
            node.placeholder = self.placeholder
            
            let makeLayout = node.asyncLayout()
            let (layout, apply) = makeLayout(self, params, self.isEnabled)
            
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            
            node.activate = self.activate
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in
                        apply(false)
                    })
                })
            }
        }
    }
    
    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? NotificationSearchItemNode {
                let layout = nodeValue.asyncLayout()
                async {
                    let (nodeLayout, apply) = layout(self, params, self.isEnabled)
                    Queue.mainQueue().async {
                        completion(nodeLayout, { _ in
                            apply(animation.isAnimated)
                        })
                    }
                }
            }
        }
    }
}

class NotificationSearchItemNode: ListViewItemNode {
    let searchBarNode: SearchBarPlaceholderNode
    private var disabledOverlay: ASDisplayNode?
    var placeholder: String?
    
    fileprivate var activate: (() -> Void)? {
        didSet {
            self.searchBarNode.activate = self.activate
        }
    }
    
    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
    
    required init() {
        self.searchBarNode = SearchBarPlaceholderNode()
        
        super.init(layerBacked: false, dynamicBounce: false)
        
        self.addSubnode(self.searchBarNode)
    }
    
    override func layoutForParams(_ params: ListViewItemLayoutParams, item: ListViewItem, previousItem: ListViewItem?, nextItem: ListViewItem?) {
        let makeLayout = self.asyncLayout()
        let (layout, apply) = makeLayout(item as! NotificationSearchItem, params, (item as! NotificationSearchItem).isEnabled)
        apply(false)
        self.contentSize = layout.contentSize
        self.insets = layout.insets
    }

    func asyncLayout() -> (_ item: NotificationSearchItem, _ params: ListViewItemLayoutParams, _ isEnabled: Bool) -> (ListViewItemNodeLayout, (Bool) -> Void) {
        let searchBarNodeLayout = self.searchBarNode.asyncLayout()
        let placeholder = self.placeholder

        return { [weak self] item, params, isEnabled in
            let baseWidth = params.width - params.leftInset - params.rightInset

            let backgroundColor = item.theme.chatList.itemBackgroundColor
            
            let placeholderString = NSAttributedString(string: placeholder ?? "", font: searchBarFont, textColor: UIColor(rgb: 0x8e8e93))
            let (_, searchBarApply) = searchBarNodeLayout(placeholderString, placeholderString, CGSize(width: baseWidth - 16.0, height: 28.0), 1.0, UIColor(rgb: 0x8e8e93), item.theme.chatList.regularSearchBarColor, backgroundColor, .immediate)
            
            let layout = ListViewItemNodeLayout(contentSize: CGSize(width: params.width, height: 44.0), insets: UIEdgeInsets())

            return (layout, { [weak self] animated in
                if let strongSelf = self {
                    let transition: ContainedViewLayoutTransition
                    if animated {
                        transition = .animated(duration: 0.3, curve: .easeInOut)
                    } else {
                        transition = .immediate
                    }

                    strongSelf.searchBarNode.frame = CGRect(origin: CGPoint(x: params.leftInset + 8.0, y: 8.0), size: CGSize(width: baseWidth - 16.0, height: 28.0))
                    searchBarApply()

                    strongSelf.searchBarNode.bounds = CGRect(origin: CGPoint(), size: CGSize(width: baseWidth - 16.0, height: 28.0))

                    if !isEnabled {
                        if strongSelf.disabledOverlay == nil {
                            let overlay = ASDisplayNode()
                            strongSelf.addSubnode(overlay)
                            strongSelf.disabledOverlay = overlay
                            if animated {
                                overlay.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                            }
                        }
                        if let overlay = strongSelf.disabledOverlay {
                            overlay.backgroundColor = backgroundColor.withAlphaComponent(0.4)
                            overlay.frame = CGRect(origin: CGPoint(x: params.leftInset + 8.0, y: 8.0), size: CGSize(width: baseWidth - 16.0, height: 28.0))
                        }
                    } else if let overlay = strongSelf.disabledOverlay {
                        strongSelf.disabledOverlay = nil
                        if animated {
                            overlay.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false, completion: { [weak overlay] _ in
                                overlay?.removeFromSupernode()
                            })
                        } else {
                            overlay.removeFromSupernode()
                        }
                    }

                    transition.updateBackgroundColor(node: strongSelf, color: backgroundColor)
                }
            })
        }
    }
}
