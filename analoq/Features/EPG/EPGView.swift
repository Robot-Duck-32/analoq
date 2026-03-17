import SwiftUI

private struct EPGLayoutMetrics {
    let overlayHeight: CGFloat
    let overlayHorizontalPadding: CGFloat
    let overlayBottomPadding: CGFloat
    let channelColumnWidth: CGFloat
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let timelineWidth: CGFloat
    let pxPerMinute: CGFloat
    let contentHorizontalPadding: CGFloat
    let contentBottomPadding: CGFloat
    let infoBarHeight: CGFloat

    static func make(for size: CGSize, windowHours: Int) -> EPGLayoutMetrics {
        let overlayHorizontalPadding: CGFloat = 18
        let overlayBottomPadding: CGFloat = 18
        let contentHorizontalPadding: CGFloat = 14
        let overlayHeight = min(size.height - 28, max(390, size.height * 0.60))
        let infoBarHeight = min(154, max(128, overlayHeight * 0.29))
        let viewportWidth = max(
            540,
            size.width - (overlayHorizontalPadding * 2) - (contentHorizontalPadding * 2) - 24
        )
        let channelColumnWidth = min(340, max(244, viewportWidth * 0.22))
        let availableTimelineWidth = max(420, viewportWidth - channelColumnWidth)
        let readableMinimumWidth = CGFloat(windowHours * 60) * 2.8
        let timelineWidth = max(availableTimelineWidth, readableMinimumWidth)
        let rowHeight = min(84, max(66, overlayHeight * 0.105))
        let headerHeight = min(54, max(44, rowHeight * 0.68))
        let pxPerMinute = timelineWidth / CGFloat(windowHours * 60)
        let contentBottomPadding: CGFloat = 18

        return EPGLayoutMetrics(
            overlayHeight: overlayHeight,
            overlayHorizontalPadding: overlayHorizontalPadding,
            overlayBottomPadding: overlayBottomPadding,
            channelColumnWidth: channelColumnWidth,
            rowHeight: rowHeight,
            headerHeight: headerHeight,
            timelineWidth: timelineWidth,
            pxPerMinute: pxPerMinute,
            contentHorizontalPadding: contentHorizontalPadding,
            contentBottomPadding: contentBottomPadding,
            infoBarHeight: infoBarHeight
        )
    }
}

struct EPGView: View {
    @ObservedObject var store: ChannelStore
    @ObservedObject var player: ChannelPlayer
    var onTuneChannel: ((AnaloqChannel) -> Void)? = nil
    var onClose: () -> Void = {}

    @State private var epg: [String: [EPGEntry]] = [:]
    @State private var selectedEntry: EPGEntry?
    @State private var showHiddenChannels = false
    @State private var timelineStart = Date.now
    @State private var didInitialScroll = false
    @FocusState private var focusedControl: FocusTarget?

    private let scheduler = ChannelScheduler()
    private let windowHours = 3

    private enum FocusTarget: Hashable {
        case toggleHiddenVisibility
        case close
        case channel(String)
        case favorite(String)
        case hidden(String)
        case program(String)
    }

    private var timelineEnd: Date {
        timelineStart.addingTimeInterval(TimeInterval(windowHours * 3600))
    }

    private func nowX(layout: EPGLayoutMetrics) -> CGFloat {
        let elapsed = Date.now.timeIntervalSince(timelineStart)
        return CGFloat(max(0, min(elapsed / 60, TimeInterval(windowHours * 60)))) * layout.pxPerMinute
    }

    private var headerEntry: EPGEntry? {
        selectedEntry ?? currentPlaybackEntry
    }

    private var currentPlaybackEntry: EPGEntry? {
        guard let channel = player.currentChannel else { return nil }
        if let liveEntry = (epg[channel.id] ?? []).first(where: { $0.isLive }) {
            return liveEntry
        }
        guard let scheduled = player.currentItem ?? scheduler.currentItem(for: channel) else { return nil }
        let startDate = scheduled.endsAt.addingTimeInterval(-scheduled.item.durationSeconds)
        return EPGEntry(
            channel: channel,
            item: scheduled.item,
            startDate: startDate,
            endDate: scheduled.endsAt
        )
    }

    private var headerNextEntry: EPGEntry? {
        guard let entry = headerEntry else { return nil }
        return nextEntry(after: entry)
    }

    private var headerArtworkURL: URL? {
        guard let entry = headerEntry else { return nil }
        return store.artworkURL(path: entry.item.thumb ?? entry.channel.artworkPath, width: 320)
    }

    private var displayedChannels: [AnaloqChannel] {
        let base = showHiddenChannels ? store.channelsIncludingHidden : store.channels
        return base.sorted { lhs, rhs in
            let lhsFav = store.isFavorite(lhs.id)
            let rhsFav = store.isFavorite(rhs.id)
            if lhsFav != rhsFav { return lhsFav && !rhsFav }
            if lhs.number != rhs.number { return lhs.number < rhs.number }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var reloadToken: String {
        let channels = displayedChannels
            .map { "\($0.id):\($0.items.count):\($0.number):\(store.isFavorite($0.id)):\(store.isHidden($0.id))" }
            .joined(separator: "|")
        return "\(channels)#\(windowHours)#\(showHiddenChannels)"
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = EPGLayoutMetrics.make(for: proxy.size, windowHours: windowHours)

            ZStack(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.16), Color.black.opacity(0.34)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                guideOverlay(layout: layout)
                    .padding(.horizontal, layout.overlayHorizontalPadding)
                    .padding(.bottom, layout.overlayBottomPadding)
            }
        }
        .contentShape(Rectangle())
        #if os(tvOS)
        .onExitCommand { onClose() }
        #endif
        .task(id: reloadToken) {
            await regenerateEPG()
        }
    }

    private func guideOverlay(layout: EPGLayoutMetrics) -> some View {
        VStack(spacing: 0) {
            overlayHeader(layout: layout)

            Rectangle()
                .fill(TVTheme.border.opacity(0.45))
                .frame(height: 1)

            ScrollViewReader { scrollProxy in
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            ForEach(displayedChannels) { channel in
                                HStack(spacing: 0) {
                                    channelCell(for: channel, layout: layout)
                                    timelineRow(for: channel, layout: layout)
                                }
                                .id(channel.id)
                                .frame(height: layout.rowHeight)
                                .overlay(alignment: .bottom) {
                                    Rectangle()
                                        .fill(TVTheme.border.opacity(0.28))
                                        .frame(height: 1)
                                }
                            }
                        } header: {
                            timelineHeader(layout: layout)
                        }
                    }
                    .frame(minWidth: layout.channelColumnWidth + layout.timelineWidth, alignment: .leading)
                    .padding(.top, 10)
                    .padding(.horizontal, layout.contentHorizontalPadding)
                    .padding(.bottom, layout.contentBottomPadding)
                }
                .onAppear {
                    guard !didInitialScroll else { return }
                    didInitialScroll = true
                    scrollToCurrentChannel(with: scrollProxy, animated: false)
                }
                .onChange(of: player.currentChannel?.id) { _, _ in
                    scrollToCurrentChannel(with: scrollProxy, animated: true)
                }
                .onChange(of: showHiddenChannels) { _, _ in
                    scrollToCurrentChannel(with: scrollProxy, animated: false)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: layout.overlayHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.24))
        )
        .tvSurface(cornerRadius: 28)
    }

    private func overlayHeader(layout: EPGLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                headerArtwork(url: headerArtworkURL)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor(for: headerEntry))
                            .frame(width: 7, height: 7)

                        Text(headerEyebrowText)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(TVTheme.textSecondary)
                            .lineLimit(1)
                    }

                    if let entry = headerEntry {
                        Text(entry.item.displayTitle)
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(TVTheme.textPrimary)
                            .lineLimit(2)

                        Text(timingText(for: entry))
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(TVTheme.textPrimary.opacity(0.92))
                            .lineLimit(1)
                    } else {
                        Text(L10n.tr("epg.loading.title"))
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(TVTheme.textPrimary)

                        Text(L10n.tr("epg.loading.subtitle"))
                            .font(.callout)
                            .foregroundStyle(TVTheme.textSecondary)
                    }
                }

                Spacer(minLength: 24)

                VStack(alignment: .trailing, spacing: 10) {
                    Text(Date.now.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(TVTheme.textPrimary)

                    HStack(spacing: 8) {
                        Text(L10n.tr("epg.now_window", windowHours))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(TVTheme.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.18), in: Capsule())

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showHiddenChannels.toggle()
                                selectedEntry = nil
                            }
                        } label: {
                            Image(systemName: showHiddenChannels ? "eye" : "eye.slash")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TVTheme.textPrimary)
                                .frame(width: 36, height: 36)
                                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(EPGNoFocusButtonStyle())
                        .focused($focusedControl, equals: .toggleHiddenVisibility)
                        .epgDisableSystemFocus()
                        .epgFocusAppearance(
                            isFocused: focusedControl == .toggleHiddenVisibility,
                            cornerRadius: 10,
                            scale: 1.005
                        )
                        .accessibilityLabel(showHiddenChannels ? L10n.tr("epg.hide_hidden") : L10n.tr("epg.show_hidden"))

                        Button(action: onClose) {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(TVTheme.textPrimary)
                                .frame(width: 36, height: 36)
                                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(EPGNoFocusButtonStyle())
                        .focused($focusedControl, equals: .close)
                        .epgDisableSystemFocus()
                        .epgFocusAppearance(isFocused: focusedControl == .close, cornerRadius: 10, scale: 1.005)
                        .accessibilityLabel(L10n.tr("common.back"))
                    }
                }
            }

            if let entry = headerEntry {
                progressBar(for: entry)
            }

            HStack(spacing: 14) {
                if let next = headerNextEntry {
                    Text(L10n.tr("epg.next_program", next.startTimeString, next.item.displayTitle))
                        .font(.caption)
                        .foregroundStyle(TVTheme.textSecondary)
                        .lineLimit(1)
                } else if headerEntry != nil {
                    Text(L10n.tr("epg.no_more_programs"))
                        .font(.caption)
                        .foregroundStyle(TVTheme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(commandHintText)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(TVTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .frame(minHeight: layout.infoBarHeight, alignment: .top)
    }

    private func headerArtwork(url: URL?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.06))

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fill)
                    default:
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(TVTheme.textSecondary)
                    }
                }
            } else {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(TVTheme.textSecondary)
            }
        }
        .frame(width: 88, height: 68)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    private var headerEyebrowText: String {
        guard let entry = headerEntry else { return L10n.tr("epg.eyebrow.default") }
        let state = headerStateText(for: entry)
        return "\(L10n.tr("channel.short", entry.channel.number)) · \(entry.channel.name.uppercased()) · \(state)"
    }

    private func headerStateText(for entry: EPGEntry) -> String {
        if entry.isLive { return L10n.tr("epg.state.live") }
        if entry.isPast { return L10n.tr("epg.state.past") }
        if selectedEntry?.id == entry.id { return L10n.tr("epg.state.selected") }
        return L10n.tr("epg.state.up_next")
    }

    private func statusColor(for entry: EPGEntry?) -> Color {
        guard let entry else { return TVTheme.textSecondary }
        if entry.isLive { return TVTheme.accent }
        return Color.white.opacity(0.65)
    }

    private func timingText(for entry: EPGEntry) -> String {
        let base = "\(entry.startTimeString) - \(entry.endTimeString)"
        if entry.isLive {
            let remainingMinutes = max(1, Int(ceil(entry.remaining / 60)))
            return L10n.tr(L10n.pluralKey("epg.timing.live", count: remainingMinutes), base, remainingMinutes)
        }
        if entry.isPast {
            return L10n.tr("epg.timing.past", base)
        }
        let startInMinutes = max(1, Int(ceil(entry.startDate.timeIntervalSinceNow / 60)))
        return L10n.tr(L10n.pluralKey("epg.timing.future", count: startInMinutes), base, startInMinutes)
    }

    private func progressValue(for entry: EPGEntry) -> CGFloat {
        if entry.isLive {
            return CGFloat(min(max(entry.progress, 0), 1))
        }
        return entry.isPast ? 1 : 0
    }

    private func progressBar(for entry: EPGEntry) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: 4)
                Capsule()
                    .fill(TVTheme.accent)
                    .frame(width: geo.size.width * progressValue(for: entry), height: 4)
            }
        }
        .frame(height: 4)
    }

    private var commandHintText: String {
        #if os(tvOS)
        return L10n.tr("epg.command_hint.tvos")
        #else
        return L10n.tr("epg.command_hint.ios")
        #endif
    }

    private func nextEntry(after entry: EPGEntry) -> EPGEntry? {
        if let next = (epg[entry.channel.id] ?? []).first(where: { $0.startDate >= entry.endDate.addingTimeInterval(-1) }) {
            if next.startDate > entry.startDate || next.item.id != entry.item.id {
                return next
            }
        }

        guard let scheduled = scheduler.currentItem(for: entry.channel, at: entry.endDate.addingTimeInterval(0.1)) else {
            return nil
        }

        return EPGEntry(
            channel: entry.channel,
            item: scheduled.item,
            startDate: entry.endDate,
            endDate: scheduled.endsAt
        )
    }

    private func timelineHeader(layout: EPGLayoutMetrics) -> some View {
        let timeStep = layout.pxPerMinute >= 3.8 ? 30 : 60
        let labelWidth: CGFloat = 72

        return HStack(spacing: 0) {
            Text(L10n.tr("epg.timeline.channels"))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(TVTheme.textSecondary)
                .frame(width: layout.channelColumnWidth, alignment: .leading)
                .padding(.horizontal, 12)
                .frame(height: layout.headerHeight)
                .background(Color.black.opacity(0.28))

            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black.opacity(0.28))

                ForEach(Array(stride(from: 0, through: windowHours * 60, by: timeStep)), id: \.self) { minute in
                    let date = timelineStart.addingTimeInterval(TimeInterval(minute * 60))
                    let x = CGFloat(minute) * layout.pxPerMinute
                    let isTerminalMarker = minute == windowHours * 60

                    Rectangle()
                        .fill(TVTheme.border.opacity(0.5))
                        .frame(width: 1, height: layout.headerHeight)
                        .offset(x: x)

                    Text(date.formatted(.dateTime.hour().minute()))
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(TVTheme.textSecondary)
                        .frame(width: labelWidth, alignment: isTerminalMarker ? .trailing : .leading)
                        .offset(
                            x: timeLabelOffset(for: minute, layout: layout, labelWidth: labelWidth),
                            y: 14
                        )
                }
            }
            .frame(width: layout.timelineWidth, height: layout.headerHeight)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(TVTheme.border.opacity(0.35))
                .frame(height: 1)
        }
    }

    private func timeLabelOffset(
        for minute: Int,
        layout: EPGLayoutMetrics,
        labelWidth: CGFloat
    ) -> CGFloat {
        if minute == windowHours * 60 {
            return max(8, layout.timelineWidth - labelWidth - 8)
        }

        let x = CGFloat(minute) * layout.pxPerMinute
        return min(max(x + 8, 8), layout.timelineWidth - labelWidth - 8)
    }

    private func channelCell(for channel: AnaloqChannel, layout: EPGLayoutMetrics) -> some View {
        HStack(spacing: 6) {
            Button {
                tuneAndClose(channel)
            } label: {
                HStack(spacing: 8) {
                    Text(String(format: "%02d", channel.number))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundStyle(TVTheme.textSecondary)
                        .frame(width: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(TVTheme.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }

                    if player.currentChannel?.id == channel.id {
                        Circle().fill(TVTheme.accent).frame(width: 8, height: 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    Color.black.opacity(player.currentChannel?.id == channel.id ? 0.32 : 0.18),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(
                            player.currentChannel?.id == channel.id
                                ? TVTheme.accent.opacity(0.35)
                                : Color.white.opacity(0.08),
                            lineWidth: 1
                        )
                )
            }
            .buttonStyle(EPGNoFocusButtonStyle())
            .focused($focusedControl, equals: .channel(channel.id))
            .epgDisableSystemFocus()
            .epgFocusAppearance(
                isFocused: focusedControl == .channel(channel.id),
                cornerRadius: 10,
                scale: 1.004
            )

            Button {
                _ = store.toggleFavorite(channelID: channel.id)
            } label: {
                Image(systemName: store.isFavorite(channel.id) ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(store.isFavorite(channel.id) ? TVTheme.accent : TVTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(EPGNoFocusButtonStyle())
            .focused($focusedControl, equals: .favorite(channel.id))
            .epgDisableSystemFocus()
            .epgFocusAppearance(isFocused: focusedControl == .favorite(channel.id), cornerRadius: 6, scale: 1.0)

            Button {
                toggleHidden(for: channel)
            } label: {
                Image(systemName: store.isHidden(channel.id) ? "eye" : "eye.slash")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TVTheme.textSecondary)
                    .frame(width: 26, height: 26)
                    .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(EPGNoFocusButtonStyle())
            .focused($focusedControl, equals: .hidden(channel.id))
            .epgDisableSystemFocus()
            .epgFocusAppearance(isFocused: focusedControl == .hidden(channel.id), cornerRadius: 6, scale: 1.0)
        }
        .padding(.horizontal, 10)
        .frame(width: layout.channelColumnWidth, height: layout.rowHeight)
        .background(Color.black.opacity(0.18))
        .overlay(alignment: .trailing) {
            Rectangle().fill(TVTheme.border.opacity(0.24)).frame(width: 1)
        }
        .opacity(store.isHidden(channel.id) ? 0.52 : 1)
    }

    private func timelineRow(for channel: AnaloqChannel, layout: EPGLayoutMetrics) -> some View {
        let entries = epg[channel.id] ?? []
        let segments = timelineSegments(entries: entries, layout: layout)

        return ZStack(alignment: .leading) {
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    switch segment.kind {
                    case .gap:
                        Color.clear.frame(width: segment.width)
                    case .entry(let entry):
                        let focusTarget = FocusTarget.program(entry.id)

                        Button {
                            selectedEntry = selectedEntry?.id == entry.id ? nil : entry
                        } label: {
                            ProgramCell(
                                entry: entry,
                                isSelected: selectedEntry?.id == entry.id,
                                isFocused: focusedControl == focusTarget,
                                compact: segment.width < 170
                            )
                        }
                        .buttonStyle(EPGNoFocusButtonStyle())
                        .focused($focusedControl, equals: focusTarget)
                        .epgDisableSystemFocus()
                        .frame(width: max(8, segment.width - 6), height: layout.rowHeight - 12)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 6)
                    }
                }
            }
            .frame(width: layout.timelineWidth, height: layout.rowHeight)

            Rectangle()
                .fill(TVTheme.accent.opacity(0.9))
                .frame(width: 2, height: layout.rowHeight)
                .offset(x: nowX(layout: layout))
        }
        .frame(width: layout.timelineWidth, height: layout.rowHeight)
        .background(Color.black.opacity(0.14))
    }

    private func timelineSegments(entries: [EPGEntry], layout: EPGLayoutMetrics) -> [TimelineSegment] {
        let totalSeconds = timelineEnd.timeIntervalSince(timelineStart)
        guard totalSeconds > 0 else { return [] }

        var segments: [TimelineSegment] = []
        var cursor = timelineStart

        func width(for duration: TimeInterval) -> CGFloat {
            max(0, layout.timelineWidth * CGFloat(duration / totalSeconds))
        }

        for entry in entries {
            let start = max(entry.startDate, timelineStart)
            let end = min(entry.endDate, timelineEnd)
            guard end > start else { continue }

            if start > cursor {
                let gapWidth = width(for: start.timeIntervalSince(cursor))
                if gapWidth > 0.5 {
                    segments.append(TimelineSegment(id: "gap-\(cursor.timeIntervalSince1970)", kind: .gap, width: gapWidth))
                }
            }

            let w = width(for: end.timeIntervalSince(start))
            if w > 0.5 {
                segments.append(TimelineSegment(id: entry.id, kind: .entry(entry), width: w))
            }

            cursor = end
            if cursor >= timelineEnd { break }
        }

        if cursor < timelineEnd {
            let tail = width(for: timelineEnd.timeIntervalSince(cursor))
            if tail > 0.5 {
                segments.append(TimelineSegment(id: "gap-tail", kind: .gap, width: tail))
            }
        }

        if segments.isEmpty {
            segments.append(TimelineSegment(id: "gap-empty", kind: .gap, width: layout.timelineWidth))
        }

        return segments
    }

    private func regenerateEPG() async {
        let channels = displayedChannels
        guard !channels.isEmpty else {
            epg = [:]
            return
        }

        timelineStart = Date.now
        let start = timelineStart
        let hours = windowHours

        let generated = await Task.detached(priority: .userInitiated) {
            EPGGenerator().generate(for: channels, from: start, hours: hours)
        }.value

        guard !Task.isCancelled else { return }
        epg = generated
    }

    private func toggleHidden(for channel: AnaloqChannel) {
        let isNowHidden = store.toggleHidden(channelID: channel.id)
        if isNowHidden && player.currentChannel?.id == channel.id {
            if let replacement = store.channels.first(where: { $0.id != channel.id }) {
                Task { await player.tune(to: replacement) }
            } else {
                player.stopPlayback()
            }
        }
        if selectedEntry?.channel.id == channel.id {
            selectedEntry = nil
        }
    }

    private func tuneAndClose(_ channel: AnaloqChannel) {
        if let onTuneChannel {
            onTuneChannel(channel)
            return
        }
        Task {
            await player.tune(to: channel)
            await MainActor.run { onClose() }
        }
    }

    private func scrollToCurrentChannel(with proxy: ScrollViewProxy, animated: Bool) {
        guard let channelID = player.currentChannel?.id,
              displayedChannels.contains(where: { $0.id == channelID }) else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(channelID, anchor: .topLeading)
                }
            } else {
                proxy.scrollTo(channelID, anchor: .topLeading)
            }
        }
    }
}

private struct TimelineSegment: Identifiable {
    enum Kind {
        case gap
        case entry(EPGEntry)
    }

    let id: String
    let kind: Kind
    let width: CGFloat
}

private struct ProgramCell: View {
    let entry: EPGEntry
    let isSelected: Bool
    let isFocused: Bool
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            if entry.isLive {
                Text(L10n.tr(compact ? "epg.badge.live.compact" : "epg.badge.live.expanded"))
                    .font(.system(size: compact ? 10 : 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(TVTheme.accent)
                    .lineLimit(1)
            }

            Text(entry.item.displayTitle)
                .font(.system(size: compact ? 13 : 15, weight: .semibold))
                .foregroundStyle(entry.isPast ? TVTheme.textSecondary : TVTheme.textPrimary)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.82)

            if !compact {
                Text("\(entry.startTimeString) - \(entry.endTimeString)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(TVTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 7 : 8)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(borderColor, lineWidth: (isFocused || isSelected) ? 1.4 : 1)
        )
        .opacity(entry.isPast ? 0.62 : 1)
    }

    private var backgroundColor: Color {
        if isFocused { return Color.white.opacity(0.18) }
        if isSelected { return Color.white.opacity(0.12) }
        if entry.isLive { return TVTheme.accent.opacity(0.16) }
        if entry.isPast { return Color.black.opacity(0.26) }
        return Color.black.opacity(0.22)
    }

    private var borderColor: Color {
        if isFocused { return Color.white.opacity(0.72) }
        if isSelected { return Color.white.opacity(0.42) }
        if entry.isLive { return TVTheme.accent.opacity(0.54) }
        return Color.white.opacity(0.14)
    }
}

struct EPGInfoPanel: View {
    let entry: EPGEntry
    @ObservedObject var player: ChannelPlayer
    var onTuneChannel: ((AnaloqChannel) -> Void)? = nil
    var onStartWatching: () -> Void = {}

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if entry.isLive {
                        Label(L10n.tr("epg.info.live_now"), systemImage: "circle.fill")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(TVTheme.accent)
                    }
                    Text(L10n.tr("epg.info.channel", entry.channel.number, entry.channel.name))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TVTheme.textSecondary)
                }

                Text(entry.item.displayTitle)
                    .font(.title3.bold())
                    .foregroundStyle(TVTheme.textPrimary)

                Text(L10n.tr(L10n.pluralKey("epg.info.duration_minutes", count: Int(entry.duration / 60)), entry.startTimeString, entry.endTimeString, Int(entry.duration / 60)))
                    .font(.caption)
                    .foregroundStyle(TVTheme.textSecondary)
            }

            Spacer()

            if entry.isLive {
                VStack(alignment: .trailing, spacing: 8) {
                    Text(L10n.tr(L10n.pluralKey("epg.info.remaining_minutes", count: Int(entry.remaining / 60)), Int(entry.remaining / 60)))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(TVTheme.textSecondary)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(TVTheme.border.opacity(0.8)).frame(height: 3)
                            Capsule().fill(TVTheme.accent).frame(width: geo.size.width * entry.progress, height: 3)
                        }
                    }
                    .frame(width: 140, height: 3)
                }
            }

            Button {
                if let onTuneChannel {
                    onTuneChannel(entry.channel)
                } else {
                    Task {
                        await player.tune(to: entry.channel)
                        await MainActor.run { onStartWatching() }
                    }
                }
            } label: {
                Label(entry.isLive ? L10n.tr("epg.info.watch") : L10n.tr("epg.info.remind"), systemImage: entry.isLive ? "play.fill" : "bell")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(TVTheme.surfaceRaised.opacity(0.56))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.34), lineWidth: 1)
                    )
            }
            .buttonStyle(EPGNoFocusButtonStyle())
            .epgDisableSystemFocus()
            .disabled(entry.isPast)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .tvSurface(cornerRadius: 14)
    }
}

private extension View {
    @ViewBuilder
    func epgDisableSystemFocus() -> some View {
        #if os(tvOS)
        self.focusEffectDisabled()
        #else
        self
        #endif
    }

    func epgFocusAppearance(
        isFocused: Bool,
        cornerRadius: CGFloat = 9,
        scale: CGFloat = 1.01
    ) -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(isFocused ? Color.white.opacity(0.72) : .clear, lineWidth: 1.4)
            )
            .scaleEffect(isFocused ? min(scale, 1.002) : 1.0)
    }
}

private struct EPGNoFocusButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.995 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}
