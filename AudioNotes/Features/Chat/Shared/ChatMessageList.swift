import SwiftUI

/// One scroll implementation; rows and scope-specific state remain composed by callers.
struct ChatMessageList<Content: View>: View {
    @Binding var scrollState: ChatScrollState
    @Binding var scrollPosition: ScrollPosition
    let messageCount: Int
    let latestMessageID: UUID?
    let activeResponseID: UUID
    let draft: String?
    let generationState: ChatGenerationState
    let sentQuestionID: UUID?
    @ViewBuilder var content: () -> Content

    private func scrollToLatest() {
        if generationState.isGenerating {
            scrollPosition.scrollTo(id: "active-\(activeResponseID)", anchor: .bottom)
        } else if let latestMessageID {
            scrollPosition.scrollTo(id: latestMessageID, anchor: .bottom)
        } else {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    private var horizontalPadding: CGFloat {
#if os(iOS)
        0 // The recording detail shell owns the reading margin.
#else
        14
#endif
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                content()
            }.frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, 14)
                .scrollTargetLayout()
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onAppear { if scrollState.followsLatest { scrollToLatest() } }
        .onScrollGeometryChange(for: ChatScrollGeometry.self) { geometry in
            ChatScrollGeometry(offset: geometry.contentOffset.y, contentHeight: geometry.contentSize.height, viewportHeight: geometry.containerSize.height)
        } action: { old, new in
            scrollState.positionChanged(nearBottom: new.nearBottom,
                userInitiated: new.movedByUser(from: old, isPositionedByUser: scrollPosition.isPositionedByUser))
        }
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting, .decelerating: scrollState.userScrolling(true)
            case .idle: scrollState.userScrolling(false)
            default: break
            }
        }
        .overlay(alignment: .bottom) {
            if scrollState.hasUnseenContent {
                Button("Jump to Latest", systemImage: "arrow.down") {
                    scrollState.jumpToLatest()
                    scrollToLatest()
                }.buttonStyle(.borderedProminent).padding(8)
                    .accessibilityLabel("Jump to latest message").accessibilityHint("Resumes following new answers")
                    .accessibilityIdentifier("chat.latest")
            }
        }
        .onChange(of: sentQuestionID) { _, _ in
            scrollState.jumpToLatest()
            scrollToLatest()
        }
        .onChange(of: draft) { _, _ in
            if scrollState.contentArrived() { scrollToLatest() }
        }
        .onChange(of: messageCount) { _, _ in
            if scrollState.contentArrived() { scrollToLatest() }
        }
        .onChange(of: generationState) { old, state in
            // One short announcement per answer: streamed text is hidden from VoiceOver while it grows.
            if old.isGenerating && state == .completed { AccessibilityNotification.Announcement("Answer ready").post() }
            if (state.isGenerating || state == .completed || state == .cancelled) && scrollState.contentArrived() { scrollToLatest() }
        }
    }
}
