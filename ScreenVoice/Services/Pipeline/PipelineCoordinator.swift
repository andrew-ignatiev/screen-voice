import Foundation
import Synchronization

enum PipelineEvent: Sendable {
    case recognized(lines: [RecognizedLine], duration: TimeInterval)
    case confirmed(String)
    case translating(Bool)
    case translated(TranslationResult)
    case failure(String)
    case captureStopped(String?)
}

@MainActor
protocol PipelineDelegate: AnyObject {
    func pipeline(_ pipeline: PipelineCoordinator, didEmit event: PipelineEvent)
}

/// Options the background loops read on every tick, so settings changes apply without a restart.
final class PipelineOptions: Sendable {
    struct Snapshot: Equatable, Sendable {
        var isPaused = false
        var framesPerSecond: Double = 4
        var minimumConfidence: Float = 0.4
        var ocr = OCRService.Options(languages: ["en-US"], accuracy: .accurate)
    }

    private let state = Mutex(Snapshot())

    var snapshot: Snapshot { state.withLock { $0 } }

    func update(_ body: @Sendable (inout Snapshot) -> Void) {
        state.withLock { body(&$0) }
    }

    func apply(_ settings: AppSettings) {
        let language = settings.sourceLanguage
        let accuracy: OCRAccuracy = language.supportsFastRecognition ? settings.ocrAccuracy : .accurate
        update {
            $0.framesPerSecond = settings.framesPerSecond
            $0.minimumConfidence = settings.minimumConfidence
            $0.ocr = OCRService.Options(languages: [language.recognitionLanguageCode], accuracy: accuracy)
        }
    }
}

/// Orchestrates capture → OCR → change detection → translation.
///
/// Two independent background loops:
/// - Recognition loop: ticks at the configured rate, runs OCR on the newest frame (skipping frames that
///   arrived while OCR was busy), feeds the change detector, and pushes confirmed phrases.
/// - Translation loop: translates confirmed phrases. Its input buffer keeps only the newest N phrases,
///   so stale subtitles are dropped instead of piling up.
/// Results reach the main actor through a single ordered event stream. Speech is driven by the delegate.
@MainActor
final class PipelineCoordinator {
    weak var delegate: PipelineDelegate?

    private let capture = CaptureService()
    private let ocr = OCRService()
    private let translator = TranslationService()
    private let options = PipelineOptions()

    private var tasks: [Task<Void, Never>] = []
    private var phraseContinuation: AsyncStream<String>.Continuation?
    private var eventContinuation: AsyncStream<PipelineEvent>.Continuation?
    private(set) var isRunning = false

    func availableWindows() async throws -> [WindowInfo] {
        try await capture.availableWindows()
    }

    func start(source: CaptureSource, settings: AppSettings) async throws {
        if isRunning { await stop() }

        try await translator.prepare(source: settings.sourceLanguage.localeLanguage, target: AppSettings.targetLanguage)

        options.apply(settings)
        options.update { $0.isPaused = false }

        let (events, eventContinuation) = AsyncStream<PipelineEvent>.makeStream()
        let (phrases, phraseContinuation) = AsyncStream<String>.makeStream(
            bufferingPolicy: .bufferingNewest(max(1, settings.maxQueuedPhrases))
        )

        do {
            try await capture.start(source: source, framesPerSecond: settings.framesPerSecond) { error in
                eventContinuation.yield(.captureStopped(error?.localizedDescription))
            }
        } catch {
            await translator.reset()
            throw error
        }

        self.eventContinuation = eventContinuation
        self.phraseContinuation = phraseContinuation
        isRunning = true

        let capture = capture
        let ocr = ocr
        let translator = translator
        let options = options

        tasks = [
            Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.delegate?.pipeline(self, didEmit: event)
                }
            },
            Task.detached(priority: .userInitiated) {
                await Self.runRecognitionLoop(
                    capture: capture, ocr: ocr, options: options,
                    phrases: phraseContinuation, events: eventContinuation
                )
            },
            Task.detached(priority: .userInitiated) {
                await Self.runTranslationLoop(phrases: phrases, translator: translator, events: eventContinuation)
            },
        ]
    }

    func stop() async {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        phraseContinuation?.finish()
        eventContinuation?.finish()
        phraseContinuation = nil
        eventContinuation = nil
        await capture.stop()
        await translator.reset()
        isRunning = false
    }

    func setPaused(_ paused: Bool) {
        options.update { $0.isPaused = paused }
    }

    func apply(_ settings: AppSettings, previous: AppSettings) {
        options.apply(settings)
        if isRunning, settings.framesPerSecond != previous.framesPerSecond {
            let capture = capture
            Task { await capture.updateFrameRate(settings.framesPerSecond) }
        }
    }

    // MARK: Background loops

    private nonisolated static func runRecognitionLoop(
        capture: CaptureService,
        ocr: OCRService,
        options: PipelineOptions,
        phrases: AsyncStream<String>.Continuation,
        events: AsyncStream<PipelineEvent>.Continuation
    ) async {
        var detector = TextChangeDetector()
        var lastSequence: UInt64 = 0
        var lines: [RecognizedLine] = []
        var wasPaused = false

        while !Task.isCancelled {
            let snapshot = options.snapshot
            let tickStart = ProcessInfo.processInfo.systemUptime

            if snapshot.isPaused {
                wasPaused = true
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            if wasPaused {
                // Re-confirm what is on screen now, but keep history so nothing is repeated.
                detector.resetCandidates()
                wasPaused = false
            }
            detector.configuration.minimumConfidence = snapshot.minimumConfidence

            // Run OCR only when a new frame arrived. Otherwise reuse the last result: ScreenCaptureKit
            // sends no frames for a static screen, and the detector still needs ticks to confirm text.
            if let frame = capture.latestFrame(), frame.sequence != lastSequence {
                lastSequence = frame.sequence
                let ocrStart = ProcessInfo.processInfo.systemUptime
                do {
                    lines = try await ocr.recognize(frame, options: snapshot.ocr)
                    events.yield(.recognized(lines: lines, duration: ProcessInfo.processInfo.systemUptime - ocrStart))
                } catch {
                    events.yield(.failure(String(localized: "Recognition error: \(error.localizedDescription)")))
                }
            }

            let now = ProcessInfo.processInfo.systemUptime
            for phrase in detector.process(lines, at: now) {
                events.yield(.confirmed(phrase))
                phrases.yield(phrase)
            }

            // Adaptive pacing: if OCR took longer than the interval, the next tick starts immediately,
            // which effectively lowers the frame rate under load.
            let interval = 1.0 / max(snapshot.framesPerSecond, AppSettings.framesPerSecondRange.lowerBound)
            let elapsed = ProcessInfo.processInfo.systemUptime - tickStart
            try? await Task.sleep(for: .seconds(max(0.02, interval - elapsed)))
        }
    }

    private nonisolated static func runTranslationLoop(
        phrases: AsyncStream<String>,
        translator: TranslationService,
        events: AsyncStream<PipelineEvent>.Continuation
    ) async {
        for await phrase in phrases {
            if Task.isCancelled { break }
            events.yield(.translating(true))
            do {
                let translated = try await translator.translate(phrase)
                if !translated.isEmpty {
                    events.yield(.translated(TranslationResult(original: phrase, translated: translated)))
                }
            } catch is CancellationError {
                break
            } catch {
                events.yield(.failure(String(localized: "Translation error: \(error.localizedDescription)")))
            }
            events.yield(.translating(false))
        }
    }
}
