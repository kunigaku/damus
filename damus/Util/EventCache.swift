//
//  EventCache.swift
//  damus
//
//  Created by William Casarin on 2023-02-21.
//

import Combine
import Foundation
import UIKit
import LinkPresentation
import Kingfisher

class ImageMetadataState {
    var state: ImageMetaProcessState
    var meta: ImageMetadata
    
    init(state: ImageMetaProcessState, meta: ImageMetadata) {
        self.state = state
        self.meta = meta
    }
}

enum ImageMetaProcessState {
    case processing
    case failed
    case processed(UIImage)
    case not_needed
    
    var img: UIImage? {
        switch self {
        case .processed(let img):
            return img
        default:
            return nil
        }
    }
}

class TranslationModel: ObservableObject {
    @Published var note_language: String?
    @Published var state: TranslateStatus
    
    init(state: TranslateStatus) {
        self.state = state
        self.note_language = nil
    }
}

class NoteArtifactsModel: ObservableObject {
    @Published var state: NoteArtifactState
    
    init(state: NoteArtifactState) {
        self.state = state
    }
}

class PreviewModel: ObservableObject {
    @Published var state: PreviewState
    
    func store(preview: LPLinkMetadata?)  {
        state = .loaded(Preview(meta: preview))
    }
    
    init(state: PreviewState) {
        self.state = state
    }
}

class ZapsDataModel: ObservableObject {
    @Published var zaps: [Zap]
    
    init(_ zaps: [Zap]) {
        self.zaps = zaps
    }
}

class RelativeTimeModel: ObservableObject {
    private(set) var last_update: Int64
    @Published var value: String {
        didSet {
            self.last_update = Int64(Date().timeIntervalSince1970)
        }
    }
    
    init(value: String) {
        self.last_update = 0
        self.value = ""
    }
}

class EventData {
    var translations_model: TranslationModel
    var artifacts_model: NoteArtifactsModel
    var preview_model: PreviewModel
    var zaps_model : ZapsDataModel
    var relative_time: RelativeTimeModel
    var validated: ValidationResult
    
    var translations: TranslateStatus {
        return translations_model.state
    }
    
    var artifacts: NoteArtifactState {
        return artifacts_model.state
    }
    
    var preview: PreviewState {
        return preview_model.state
    }
    
    var zaps: [Zap] {
        return zaps_model.zaps
    }
    
    init(zaps: [Zap] = []) {
        self.translations_model = .init(state: .havent_tried)
        self.artifacts_model = .init(state: .not_loaded)
        self.zaps_model = .init(zaps)
        self.validated = .unknown
        self.preview_model = .init(state: .not_loaded)
        self.relative_time = .init(value: "")
    }
}

class EventCache {
    private var events: [String: NostrEvent] = [:]
    private var replies = ReplyMap()
    private var cancellable: AnyCancellable?
    private var image_metadata: [String: ImageMetadataState] = [:]
    private var event_data: [String: EventData] = [:]
    
    //private var thread_latest: [String: Int64]
    
    init() {
        cancellable = NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        ).sink { [weak self] _ in
            self?.prune()
        }
    }
    
    func get_cache_data(_ evid: String) -> EventData {
        guard let data = event_data[evid] else {
            let data = EventData()
            event_data[evid] = data
            return data
        }
        
        return data
    }
    
    func is_event_valid(_ evid: String) -> ValidationResult {
        return get_cache_data(evid).validated
    }
    
    func store_event_validation(evid: String, validated: ValidationResult) {
        get_cache_data(evid).validated = validated
    }
    
    func store_translation_artifacts(evid: String, translated: TranslateStatus) {
        get_cache_data(evid).translations_model.state = translated
    }
    
    func store_artifacts(evid: String, artifacts: NoteArtifacts) {
        get_cache_data(evid).artifacts_model.state = .loaded(artifacts)
    }
    
    @discardableResult
    func store_zap(zap: Zap) -> Bool {
        let data = get_cache_data(zap.target.id).zaps_model
        return insert_uniq_sorted_zap_by_amount(zaps: &data.zaps, new_zap: zap)
    }
    
    func lookup_zaps(target: ZapTarget) -> [Zap] {
        return get_cache_data(target.id).zaps_model.zaps
    }
    
    func store_img_metadata(url: URL, meta: ImageMetadataState) {
        self.image_metadata[url.absoluteString.lowercased()] = meta
    }
    
    func lookup_artifacts(evid: String) -> NoteArtifactState {
        return get_cache_data(evid).artifacts_model.state
    }
    
    func lookup_img_metadata(url: URL) -> ImageMetadataState? {
        return image_metadata[url.absoluteString.lowercased()]
    }
    
    func lookup_translated_artifacts(evid: String) -> TranslateStatus? {
        return get_cache_data(evid).translations_model.state
    }
    
    func parent_events(event: NostrEvent) -> [NostrEvent] {
        var parents: [NostrEvent] = []
        
        var ev = event
        
        while true {
            guard let direct_reply = ev.direct_replies(nil).last else {
                break
            }
            
            guard let next_ev = lookup(direct_reply.ref_id), next_ev != ev else {
                break
            }
            
            parents.append(next_ev)
            ev = next_ev
        }
        
        return parents.reversed()
    }
    
    func add_replies(ev: NostrEvent) {
        for reply in ev.direct_replies(nil) {
            replies.add(id: reply.ref_id, reply_id: ev.id)
        }
    }
    
    func child_events(event: NostrEvent) -> [NostrEvent] {
        guard let xs = replies.lookup(event.id) else {
            return []
        }
        let evs: [NostrEvent] = xs.reduce(into: [], { evs, evid in
            guard let ev = self.lookup(evid) else {
                return
            }
            
            evs.append(ev)
        }).sorted(by: { $0.created_at < $1.created_at })
        return evs
    }
    
    func upsert(_ ev: NostrEvent) -> NostrEvent {
        if let found = lookup(ev.id) {
            return found
        }
        
        insert(ev)
        return ev
    }
    
    func lookup(_ evid: String) -> NostrEvent? {
        return events[evid]
    }
    
    func insert(_ ev: NostrEvent) {
        guard events[ev.id] == nil else {
            return
        }
        events[ev.id] = ev
    }
    
    private func prune() {
        events = [:]
        event_data = [:]
        replies.replies = [:]
    }
}

func should_translate(event: NostrEvent, our_keypair: Keypair, settings: UserSettingsStore, note_lang: String?) -> Bool {
    guard settings.can_translate else {
        return false
    }
    
    // Do not translate self-authored notes if logged in with a private key
    // as we can assume the user can understand their own notes.
    // The detected language prediction could be incorrect and not in the list of preferred languages.
    // Offering a translation in this case is definitely incorrect so let's avoid it altogether.
    if our_keypair.privkey != nil && our_keypair.pubkey == event.pubkey {
        return false
    }
    
    if let note_lang {
        let preferredLanguages = Set(Locale.preferredLanguages.map { localeToLanguage($0) })
        
        // Don't translate if its in our preferred languages
        guard !preferredLanguages.contains(note_lang) else {
            // if its the same, give up and don't retry
            return false
        }
    }
    
    // we should start translating if we have auto_translate on
    return true
}

func should_preload_translation(event: NostrEvent, our_keypair: Keypair, current_status: TranslateStatus, settings: UserSettingsStore, note_lang: String?) -> Bool {
    
    switch current_status {
    case .havent_tried:
        return should_translate(event: event, our_keypair: our_keypair, settings: settings, note_lang: note_lang) && settings.auto_translate
    case .translating: return false
    case .translated: return false
    case .not_needed: return false
    }
}



struct PreloadResult {
    let event: NostrEvent
    let artifacts: NoteArtifacts?
    let translations: TranslateStatus?
    let preview: Preview?
    let timeago: String
    let note_language: String
}


struct PreloadPlan {
    let data: EventData
    let event: NostrEvent
    let load_artifacts: Bool
    let load_translations: Bool
    let load_preview: Bool
}

func load_preview(artifacts: NoteArtifacts) async -> Preview? {
    guard let link = artifacts.links.first else {
        return nil
    }
    let meta = await Preview.fetch_metadata(for: link)
    return Preview(meta: meta)
}

func get_preload_plan(cache: EventData, ev: NostrEvent, our_keypair: Keypair, settings: UserSettingsStore) -> PreloadPlan? {
    let load_artifacts = cache.artifacts.should_preload
    if load_artifacts {
        cache.artifacts_model.state = .loading
    }
    
    let load_translations = should_preload_translation(event: ev, our_keypair: our_keypair, current_status: cache.translations, settings: settings, note_lang: cache.translations_model.note_language)
    if load_translations {
        cache.translations_model.state = .translating
    }
    
    let load_preview = cache.preview.should_preload
    if load_preview {
        cache.preview_model.state = .loading
    }
    
    if !load_artifacts && !load_translations && !load_preview {
        return nil
    }
    
    return PreloadPlan(data: cache, event: ev, load_artifacts: load_artifacts, load_translations: load_translations, load_preview: load_preview)
}

func preload_event(plan: PreloadPlan, profiles: Profiles, our_keypair: Keypair, settings: UserSettingsStore) async -> PreloadResult {
    var artifacts: NoteArtifacts? = nil
    var translations: TranslateStatus? = nil
    var preview: Preview? = nil
    
    print("Preloading event \(plan.event.content)")
    
    if plan.load_artifacts {
        artifacts = render_note_content(ev: plan.event, profiles: profiles, privkey: our_keypair.privkey)
        let arts = artifacts!
        
        for url in arts.images {
            print("Preloading image \(url.absoluteString)")
            KingfisherManager.shared.retrieveImage(with: ImageResource(downloadURL: url)) { val in
                print("Finished preloading image \(url.absoluteString)")
            }
        }
    }
    
    if plan.load_preview {
        if let arts = artifacts ?? plan.data.artifacts.artifacts {
            preview = await load_preview(artifacts: arts)
        } else {
            print("couldnt preload preview")
        }
    }
    
    let note_language = plan.event.note_language(our_keypair.privkey) ?? current_language()
    
    if plan.load_translations, should_translate(event: plan.event, our_keypair: our_keypair, settings: settings, note_lang: note_language) {
        translations = await translate_note(profiles: profiles, privkey: our_keypair.privkey, event: plan.event, settings: settings, note_lang: note_language)
    }
    
    return PreloadResult(event: plan.event, artifacts: artifacts, translations: translations, preview: preview, timeago: format_relative_time(plan.event.created_at), note_language: note_language)
}

func set_preload_results(plan: PreloadPlan, res: PreloadResult, privkey: String?) {
    if plan.load_translations {
        if let translations = res.translations {
            plan.data.translations_model.state = translations
        } else {
            // failed
            plan.data.translations_model.state = .not_needed
        }
    }
    
    if plan.load_artifacts, case .loading = plan.data.artifacts {
        if let artifacts = res.artifacts {
            plan.data.artifacts_model.state = .loaded(artifacts)
        } else {
            plan.data.artifacts_model.state = .loaded(.just_content(plan.event.get_content(privkey)))
        }
    }
    
    if plan.load_preview, case .loading = plan.data.preview {
        if let preview = res.preview {
            plan.data.preview_model.state = .loaded(preview)
        } else {
            plan.data.preview_model.state = .loaded(.failed)
        }
    }
    
    plan.data.translations_model.note_language = res.note_language
    plan.data.relative_time.value = res.timeago
}

func preload_events(event_cache: EventCache, events: [NostrEvent], profiles: Profiles, our_keypair: Keypair, settings: UserSettingsStore) {
    
    let plans = events.compactMap { ev in
        get_preload_plan(cache: event_cache.get_cache_data(ev.id), ev: ev, our_keypair: our_keypair, settings: settings)
    }
    
    Task.init {
        for plan in plans {
            let res = await preload_event(plan: plan, profiles: profiles, our_keypair: our_keypair, settings: settings)
            // dispatch results right away
            DispatchQueue.main.async { [plan] in
                set_preload_results(plan: plan, res: res, privkey: our_keypair.privkey)
            }
        }
    }
    
}

