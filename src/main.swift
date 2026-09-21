import AppKit
import Foundation
import MetalKit
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

// ─────────────────────────────────────────────────────────────────────────────
// Пути
// ─────────────────────────────────────────────────────────────────────────────

let home = FileManager.default.homeDirectoryForCurrentUser
let configDir = home.appendingPathComponent(".config/adaptive-brightness", isDirectory: true)
let stateDir  = home.appendingPathComponent(".local/state/adaptive-brightness", isDirectory: true)
let configURL = configDir.appendingPathComponent("config.json")
let stateURL  = stateDir.appendingPathComponent("state.json")
let logURL    = stateDir.appendingPathComponent("daemon.log")

func ensureDirs() {
    for d in [configDir, stateDir] {
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Конфиг
// ─────────────────────────────────────────────────────────────────────────────

struct Config {
    /// В конфиге остался ключ от прежнего контура первого порядка. Смысла у него
    /// больше нет, но молча игнорировать чужую настройку нельзя — скажем в логе.
    var legacyTauBrightness = false

    /// Частота контура управления, Гц. Яркость пересчитывается и пишется с этим
    /// темпом, и от него напрямую зависит, видно ли ступеньки на ходу.
    ///
    /// Замерено: на 30 Гц большой ход идёт шагами по 1.4% яркости — это видно
    /// глазом. Панель при этом различает уровни мельче 0.1%, то есть предел
    /// ставило не железо, а наш темп. На 120 планировщик реально выдаёт 83–85
    /// тактов в секунду (восьмимиллисекундный сон он не держит), и шаг падает
    /// до 0.3% — ступенек не видно. Цена вопроса мизерная: чтение яркости
    /// стоит 0.068 мс, запись 0.004 мс, вместе это меньше процента ядра.
    ///
    /// Пружина считает по фактическому шагу времени, поэтому недобор частоты
    /// искажает не траекторию, а только плотность точек на ней.
    var controlHz: Double = 120
    /// Частота съёма кадра, Гц. Кадр дешевле записи яркости, но composition не бесплатен.
    var captureHz: Double = 10

    /// Во сколько раз яркость на полностью светлом контенте ниже, чем на тёмном.
    /// 0.6 ≈ «85% на тёмном → 51% на светлом».
    var span: Double = 0.6
    /// Светлота кадра, которая считается «полностью тёмным» экраном (тёмная IDE ≈ 0.12–0.22).
    var darkPoint: Double = 0.15
    /// Светлота кадра, которая считается «полностью светлым» (светлый браузер ≈ 0.75–0.88).
    var lightPoint: Double = 0.80

    /// Жёсткие границы, за которые демон не выходит.
    var minBrightness: Double = 0.15
    var maxBrightness: Double = 1.0

    /// Постоянная времени сглаживания светлоты, сек. За tau проходится 63% пути.
    /// Больше — инертнее к вспышкам и скроллу, но медленнее реакция на смену приложения.
    var tauLuma: Double = 0.6
    /// Время фактического прихода яркости к цели, сек. Ход ведёт критически
    /// демпфированная пружина: мягкий старт, максимум скорости в середине,
    /// приход без перелёта. Цель пересчитывается каждый такт, поэтому смена
    /// контента посреди хода подхватывается сразу.
    var travelTime: Double = 1.1

    /// Из покоя трогаемся, только когда цель разошлась с яркостью больше этого.
    /// Гистерезис против мелкой ряби контента; уже идущий ход не тормозит.
    var startThreshold: Double = 0.015
    /// Ход завершён, когда и остаток, и шаг за такт стали меньше этого.
    var stopThreshold: Double = 0.002
    /// Расхождение «что я записал» vs «что стоит», которое считается внешней
    /// правкой. Чтение возвращает записанное бит-в-бит, поэтому порог держим
    /// много ниже шага клавиш яркости (1/16 = 0.0625).
    var manualEpsilon: Double = 0.01
    /// Тишина после последнего внешнего изменения, после которой серия нажатий
    /// считается законченной и пишется одной строкой в лог, сек.
    var manualQuietPeriod: Double = 0.6
    /// Насколько должна уехать нормированная светлота от той, при которой ты
    /// правил яркость, чтобы демон счёл контент сменившимся и снова взялся вести.
    var resumeLumaDelta: Double = 0.12

    /// Сколько не снимать кадры после последнего события жеста на трекпаде, сек.
    ///
    /// Съём во время анимации рвёт кадр вертикальными полосами, а жест —
    /// единственный сигнал, приходящий до анимации, а не после неё. 0 выключает.
    ///
    /// Держать здесь всю длину анимации не надо и вредно. Это число — не
    /// «сколько идёт переход», а «сколько не лезть под руку, пока пальцы
    /// работают»: конец перехода определяется по самой картинке, ожиданием
    /// устоявшейся светлоты, и оно же отбраковывает рваные кадры — те не
    /// устаиваются. Пока здесь стояла вся анимация с запасом, после её конца
    /// демон ещё почти секунду ничего не делал, и переход ощущался вялым.
    var gestureSettle: Double = 0.25

    /// Сколько не снимать кадры и не трогать яркость после смены рабочего
    /// стола, сек.
    ///
    /// Съём во время анимации перехода рвёт кадр вертикальными полосами:
    /// запрос на захват заставляет оконный сервер собрать внеочередной кадр
    /// ровно тогда, когда он рисует переход. Ждём, пока анимация закончится.
    var spaceSettle: Double = 0.8

    /// Сколько после перехода, отработанного по жесту, не верить сигналу о
    /// смене рабочего стола, сек.
    ///
    /// Номер стола SkyLight отдаёт с запозданием: анимация давно кончилась,
    /// светлота устоялась, демон уже ведёт яркость — и только теперь номер
    /// меняется. Без этой отсрочки переход глушится второй раз, ход рвётся
    /// пополам, и человек видит паузу ровно в середине.
    var spaceGrace: Double = 2.0

    /// Сколько не трогать яркость после пробуждения экрана, сек.
    ///
    /// macOS сама плавно поднимает подсветку при выходе из сна и после
    /// разблокировки. Если писать своё значение в это же время, два регулятора
    /// дерутся за одну ручку, и это видно как быстрое промаргивание. Ждём, пока
    /// система закончит, и только потом синхронизируемся и продолжаем.
    var wakeSettle: Double = 2.0

    /// Сколько надо продержать обе клавиши яркости вместе, чтобы это
    /// засчиталось аккордом, сек. Короче — легче задеть случайно.
    var chordHold: Double = 0.2

    /// Сколько после последнего события клавиш яркости ждать продолжения
    /// серии, сек. Пока не истекло, серия считается незаконченной.
    var keySettle: Double = 0.35

    /// Сколько подсветка должна простоять неподвижно, чтобы серия считалась
    /// доведённой до конца, сек. Ждать только тишины на клавишах мало:
    /// системный рамп идёт своим темпом и после последнего нажатия.
    var keyStill: Double = 0.2

    /// Предохранитель: дольше этого серия не длится ни при каких условиях, сек.
    /// Иначе застрявший рамп или чужая анимация оставили бы демон немым.
    var keySeriesMax: Double = 4.0

    /// Насколько сглаженная светлота должна сойтись с сырой, чтобы считаться
    /// установившейся. Пока не сошлась, точка отсчёта после ручной правки
    /// дописывается: иначе baseline привязывается к светлоте, которой на
    /// экране не было — она ещё ехала к светлоте нового окна.
    var lumaSettleEps: Double = 0.012

    /// Предел на это дописывание, сек. Обязателен: на видео сырая светлота
    /// скачет без остановки, сглаженная не догонит её никогда, и без предела
    /// демон остался бы в паузе навсегда. При `tauLuma` 0.6 сглаживание
    /// сходится примерно за 1.8 с, так что предел стоит держать выше.
    var lumaSettleMax: Double = 2.5

    /// Разведка при старте: что демон видит на неактивных столах. Пишет в лог
    /// по строке на стол и выключается сам — это диагностика, не режим работы.
    var probeSpaces = false

    /// Писать в лог каждое событие клавиш яркости — для разбора проблем.
    var traceKeys = false

    /// Расширить перехват на жесты и колесо и писать в лог их типы. Нужно,
    /// чтобы понять, какие события вообще видны от свайпа смены рабочего стола.
    /// Все они пропускаются насквозь, перехват только наблюдает.
    var traceEvents = false

    /// Перехватывать родные клавиши яркости, чтобы они продолжали работать
    /// выше 100%. Требует разрешения Accessibility: без него буст остаётся
    /// доступен только через `adaptive-brightness boost`.
    var nativeKeysBoost = true

    /// Потолок буста на XDR-панели. 1.0 — буст запрещён, 1.6 ≈ «160%».
    /// Выше запаса EDR смысла поднимать нет: значения всё равно обрежутся.
    var maxBoost: Double = 1.6

    /// Сколько секунд после запуска терпеть отсутствие кадров, прежде чем
    /// сдаться и выйти.
    ///
    /// На входе в систему оконный сервер бывает ещё не готов отдавать кадры,
    /// и первый снимок падает вовсе не из-за разрешений. Раньше демон в этом
    /// случае сразу выходил, launchd поднимал его через ThrottleInterval, и так
    /// по кругу: яркость не управлялась первые полминуты, а в лог сыпались
    /// строки про невыданное разрешение, которого на деле никто не отзывал.
    ///
    /// Обратная сторона: если разрешения действительно нет, демон узнает об
    /// этом не сразу, а через это окно, и всё время будет висеть в памяти.
    /// Первую неудачу пишем в лог сразу, чтобы молчания не было.
    var startupGrace: Double = 90

    /// Не трогать яркость, пока macOS держит Game Mode.
    ///
    /// Ловится по `com.apple.system.console_mode_changed` («Console Mode» —
    /// внутреннее имя Game Mode): 0 — выключен, 1 — включён, после выхода из
    /// игры сам возвращается в 0.
    ///
    /// Срабатывает только для игр, которые macOS сама опознала как игры —
    /// список лежит в `com.apple.GamePolicyAgent`, ключ `installedGames`. Для
    /// игр под CrossOver, Wine и прочими обёртками Game Mode не включается
    /// вообще: система видит только обёртку, у которой нет категории
    /// «игра». Для них есть `pauseApps`.
    var pauseOnGameMode = true

    /// Не трогать яркость, пока впереди приложение с таким bundle id.
    /// Сравнение по префиксу, поэтому "com.codeweavers." накрывает все
    /// CrossOver-игры разом, а "org.ryujinx." — конкретный эмулятор.
    var pauseApps: [String] = ["com.codeweavers."]

    /// Как снимать кадры.
    ///
    /// `shot` — одиночные снимки в отдельной задаче. Постоянной сессии захвата
    /// нет, поэтому macOS не показывает индикатор «идёт запись экрана» в
    /// меню-баре. Каждый снимок стоит ~35 мс независимо от того, менялась ли
    /// картинка.
    ///
    /// `stream` — постоянный SCStream. На статичном экране кадры не приходят
    /// вовсе, так что съём почти бесплатен, но индикатор записи экрана висит
    /// всё время работы демона. Скрыть его нельзя: это привилегия системы.
    var captureMode = "shot"

    /// Разрешение кадра для анализа.
    var sampleWidth: Int = 96
    var sampleHeight: Int = 62

    static func load() -> Config {
        var c = Config()
        guard let data = try? Data(contentsOf: configURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return c }
        func d(_ k: String, _ cur: Double) -> Double { (raw[k] as? NSNumber)?.doubleValue ?? cur }
        func i(_ k: String, _ cur: Int) -> Int { (raw[k] as? NSNumber)?.intValue ?? cur }
        c.controlHz       = d("controlHz", c.controlHz)
        c.captureHz       = d("captureHz", c.captureHz)
        c.span            = d("span", c.span)
        c.darkPoint       = d("darkPoint", c.darkPoint)
        c.lightPoint      = d("lightPoint", c.lightPoint)
        c.minBrightness   = d("minBrightness", c.minBrightness)
        c.maxBrightness   = d("maxBrightness", c.maxBrightness)
        c.tauLuma         = d("tauLuma", c.tauLuma)
        c.travelTime      = d("travelTime", c.travelTime)
        c.manualQuietPeriod = d("manualQuietPeriod", c.manualQuietPeriod)
        c.resumeLumaDelta = d("resumeLumaDelta", c.resumeLumaDelta)
        if raw["travelTime"] == nil, raw["tauBrightness"] != nil { c.legacyTauBrightness = true }
        c.startThreshold  = d("startThreshold", c.startThreshold)
        c.stopThreshold   = d("stopThreshold", c.stopThreshold)
        c.manualEpsilon   = d("manualEpsilon", c.manualEpsilon)
        c.captureMode     = (raw["captureMode"] as? String) ?? c.captureMode
        c.gestureSettle   = d("gestureSettle", c.gestureSettle)
        c.spaceSettle     = d("spaceSettle", c.spaceSettle)
        c.spaceGrace      = d("spaceGrace", c.spaceGrace)
        c.wakeSettle      = d("wakeSettle", c.wakeSettle)
        c.maxBoost        = d("maxBoost", c.maxBoost)
        c.nativeKeysBoost = (raw["nativeKeysBoost"] as? NSNumber)?.boolValue ?? c.nativeKeysBoost
        c.chordHold       = d("chordHold", c.chordHold)
        c.keySettle       = d("keySettle", c.keySettle)
        c.keyStill        = d("keyStill", c.keyStill)
        c.keySeriesMax    = d("keySeriesMax", c.keySeriesMax)
        c.lumaSettleEps   = d("lumaSettleEps", c.lumaSettleEps)
        c.lumaSettleMax   = d("lumaSettleMax", c.lumaSettleMax)
        c.probeSpaces     = (raw["probeSpaces"] as? NSNumber)?.boolValue ?? c.probeSpaces
        c.traceKeys       = (raw["traceKeys"] as? NSNumber)?.boolValue ?? c.traceKeys
        c.traceEvents     = (raw["traceEvents"] as? NSNumber)?.boolValue ?? c.traceEvents
        c.startupGrace    = d("startupGrace", c.startupGrace)
        c.pauseOnGameMode = (raw["pauseOnGameMode"] as? NSNumber)?.boolValue ?? c.pauseOnGameMode
        c.pauseApps       = (raw["pauseApps"] as? [String]) ?? c.pauseApps
        c.sampleWidth     = i("sampleWidth", c.sampleWidth)
        c.sampleHeight    = i("sampleHeight", c.sampleHeight)
        return c
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Состояние: baseline, который задаёт пользователь руками
// ─────────────────────────────────────────────────────────────────────────────

struct State {
    /// Яркость, которую пользователь выставил руками.
    var baseline: Double
    /// Светлота экрана в момент, когда он её выставил.
    var baselineLuma: Double
    /// Последнее значение, которое демон записал сам, — чтобы отличить ручную правку.
    var lastWritten: Double
    /// Адаптация включена. Выключается аккордом «ярче + тусклее» и переживает
    /// перезапуск демона: решение принято руками, отменять его молча нельзя.
    var enabled: Bool = true
    /// Светлота, при которой была ручная правка, пока демон держит паузу.
    /// nil — паузы нет, демон ведёт яркость. Лежит в state, чтобы `status` мог
    /// объяснить, почему яркость не двигается.
    var holdLuma: Double?

    func save() {
        var obj: [String: Any] = [
            "baseline": baseline,
            "baselineLuma": baselineLuma,
            "lastWritten": lastWritten,
        ]
        obj["enabled"] = enabled
        if let h = holdLuma { obj["holdLuma"] = h }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    static func load() -> State? {
        guard let data = try? Data(contentsOf: stateURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b = (raw["baseline"] as? NSNumber)?.doubleValue,
              let l = (raw["baselineLuma"] as? NSNumber)?.doubleValue else { return nil }
        let w = (raw["lastWritten"] as? NSNumber)?.doubleValue ?? b
        let h = (raw["holdLuma"] as? NSNumber)?.doubleValue
        let en = (raw["enabled"] as? NSNumber)?.boolValue ?? true
        return State(baseline: b, baselineLuma: l, lastWritten: w, enabled: en, holdLuma: h)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Подсветка встроенного дисплея (приватный DisplayServices)
// ─────────────────────────────────────────────────────────────────────────────

final class Backlight {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getFn: GetFn
    private let setFn: SetFn

    init?() {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_NOW),
              let g = dlsym(handle, "DisplayServicesGetBrightness"),
              let s = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        getFn = unsafeBitCast(g, to: GetFn.self)
        setFn = unsafeBitCast(s, to: SetFn.self)
    }

    func read(_ display: CGDirectDisplayID) -> Double? {
        var v: Float = 0
        guard getFn(display, &v) == 0 else { return nil }
        return Double(v)
    }

    @discardableResult
    func write(_ display: CGDirectDisplayID, _ value: Double) -> Bool {
        setFn(display, Float(max(0, min(1, value)))) == 0
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Снятие кадра и расчёт воспринимаемой светлоты
// ─────────────────────────────────────────────────────────────────────────────

/// sRGB → линейный свет. Усреднять надо именно линейные величины: усреднение
/// гамма-кодированных байт завысило бы вклад тёмных областей.
let linearLUT: [Double] = (0...255).map { i -> Double in
    let c = Double(i) / 255.0
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

final class ScreenSampler: @unchecked Sendable {
    private let config: SCStreamConfiguration
    private var filter: SCContentFilter?
    private var filterRefreshed = Date.distantPast

    init(width: Int, height: Int) {
        let c = SCStreamConfiguration()
        c.width = width
        c.height = height
        c.showsCursor = false
        c.capturesAudio = false
        config = c
    }

    private func currentFilter() async throws -> SCContentFilter {
        // Фильтр кэшируем: SCShareableContent — заметно дороже самого кадра.
        if let f = filter, Date().timeIntervalSince(filterRefreshed) < 60 { return f }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw NSError(domain: "adaptive-brightness", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "нет доступных дисплеев"])
        }
        let f = SCContentFilter(display: display, excludingWindows: [])
        filter = f
        filterRefreshed = Date()
        return f
    }

    func invalidate() { filter = nil }

    /// Воспринимаемая светлота кадра в [0..1].
    func luma() async throws -> Double {
        let f = try await currentFilter()
        let image = try await SCScreenshotManager.captureImage(contentFilter: f, configuration: config)
        return ScreenSampler.perceivedLuma(image)
    }

    static func perceivedLuma(_ image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return 0 }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: bitmapInfo) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var sum = 0.0
        for i in stride(from: 0, to: w * h * 4, by: 4) {
            sum += 0.2126 * linearLUT[Int(buf[i])]
                 + 0.7152 * linearLUT[Int(buf[i + 1])]
                 + 0.0722 * linearLUT[Int(buf[i + 2])]
        }
        let meanLinear = sum / Double(w * h)
        // Обратно в перцептивную шкалу — чтобы шкала совпадала с тем, как глаз
        // оценивает «тёмный / светлый» интерфейс.
        return pow(max(0, min(1, meanLinear)), 1.0 / 2.2)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Когда яркость трогать не надо
// ─────────────────────────────────────────────────────────────────────────────

// Функции notify(3) в модуль Darwin не экспортированы — объявляем сами.
@_silgen_name("notify_register_check")
func notify_register_check(_ name: UnsafePointer<CChar>, _ token: UnsafeMutablePointer<Int32>) -> UInt32
@_silgen_name("notify_get_state")
func notify_get_state(_ token: Int32, _ state: UnsafeMutablePointer<UInt64>) -> UInt32
@_silgen_name("notify_set_state")
func notify_set_state(_ token: Int32, _ state: UInt64) -> UInt32
@_silgen_name("notify_post")
func notify_post(_ name: UnsafePointer<CChar>) -> UInt32
@_silgen_name("notify_cancel")
func notify_cancel(_ token: Int32) -> UInt32

/// Токен notify(3), взятый один раз на весь процесс.
///
/// Регистрация не бесплатная и сама не убирается: каждый
/// `notify_register_check` занимает слот в таблице процесса, и слотов ровно
/// 10 000. При попытке занять 10 001-й libnotify не возвращает ошибку, а
/// убивает процесс SIGTRAP. Отсюда были падения каждые три минуты: два чтения
/// на такт 30 Гц выбирали лимит за ~166 секунд, launchd поднимал демон заново,
/// а заодно macOS переспрашивала разрешение на запись экрана.
///
/// Поэтому токен берётся один раз и живёт до конца процесса. Если notifyd
/// перезапустится, токен протухнет — операция, вернувшая ошибку, освобождает
/// слот и сбрасывает кэш, и следующий вызов регистрируется заново. Число таких
/// перерегистраций ограничено: даже если освободить слот не удастся, к лимиту
/// это подойти не даст.
final class NotifyToken: @unchecked Sendable {
    private static let maxRetries = 64

    private let name: String
    private let lock = NSLock()
    private var token: Int32 = -1
    private var retries = 0

    init(_ name: String) { self.name = name }

    /// Токен, регистрируя его при первом обращении. nil — зарегистрировать не
    /// вышло или запас перерегистраций исчерпан.
    private func acquire() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if token >= 0 { return token }
        guard retries <= NotifyToken.maxRetries else { return nil }
        retries += 1
        var t: Int32 = 0
        guard notify_register_check(name, &t) == 0 else { return nil }
        token = t
        return t
    }

    private func invalidate() {
        lock.lock(); defer { lock.unlock() }
        if token >= 0 { _ = notify_cancel(token) }
        token = -1
    }

    func get() -> UInt64? {
        guard let t = acquire() else { return nil }
        var v: UInt64 = 0
        guard notify_get_state(t, &v) == 0 else { invalidate(); return nil }
        return v
    }

    @discardableResult
    func set(_ value: UInt64) -> Bool {
        guard let t = acquire() else { return false }
        guard notify_set_state(t, value) == 0 else { invalidate(); return false }
        return true
    }

    func post() { _ = notify_post(name) }
}

/// Уровень буста передаётся из CLI в демон через Darwin-уведомление: демон
/// читает его из разделяемой памяти на каждом такте, это дешевле файла и не
/// требует ни сокета, ни слежения за файловой системой.
let boostNotification = "com.geforester.adaptive-brightness.boost"

/// Состояние перехвата клавиш, чтобы `status` показывал положение дел в
/// демоне. Спрашивать AXIsProcessTrusted() в процессе CLI бессмысленно: права
/// там принадлежат терминалу, из которого его запустили, а не демону.
let tapStatusNotification = "com.geforester.adaptive-brightness.keytap"

enum TapStatusChannel {
    private static let channel = NotifyToken(tapStatusNotification)

    static func read() -> Bool? {
        guard let v = channel.get() else { return nil }
        return v == 2      // 1 — выключен, 2 — включён, 0 — демон не сообщал
    }

    static func write(_ active: Bool) {
        channel.set(active ? 2 : 1)
    }
}

/// Включена ли адаптация. Через файл состояния это делать нельзя: демон держит
/// его в памяти и затирает своей копией, так что правка снаружи пропала бы.
let enableNotification = "com.geforester.adaptive-brightness.enabled"

enum EnableChannel {
    private static let channel = NotifyToken(enableNotification)

    /// nil — никто ещё не сообщал.
    static func read() -> Bool? {
        guard let v = channel.get(), v > 0 else { return nil }
        return v == 2      // 1 — выключено, 2 — включено
    }

    @discardableResult
    static func write(_ on: Bool) -> Bool {
        guard channel.set(on ? 2 : 1) else { return false }
        channel.post()
        return true
    }
}

/// Уровень хранится как целое в тысячных: 1.0 → 1000, 1.35 → 1350.
enum BoostChannel {
    private static let channel = NotifyToken(boostNotification)

    static func read() -> Double? {
        guard let v = channel.get(), v > 0 else { return nil }
        return Double(v) / 1000.0
    }

    @discardableResult
    static func write(_ level: Double) -> Bool {
        guard channel.set(UInt64((level * 1000).rounded())) else { return false }
        channel.post()
        return true
    }
}

/// Состояние Game Mode через Darwin-уведомление. Замерено: при запуске игры,
/// которую macOS считает игрой, значение уходит 0 → 1, после выхода само
/// возвращается в 0. Чтение дешёвое — это разделяемая память, не XPC.
final class GameModeWatch {
    private var token: Int32 = -1
    private let registered: Bool

    init() {
        var t: Int32 = 0
        registered = notify_register_check("com.apple.system.console_mode_changed", &t) == 0
        if registered { token = t }
    }

    /// false и в случае, когда уведомление недоступно: лучше продолжать вести
    /// яркость, чем молча замереть навсегда из-за неопознанного состояния.
    var active: Bool {
        guard registered else { return false }
        var v: UInt64 = 0
        guard notify_get_state(token, &v) == 0 else { return false }
        return v != 0
    }

    var available: Bool { registered }
}

/// Номер текущего пространства (рабочего стола) через приватный SkyLight.
/// Вызов практически бесплатный — замерено 0.001 мс в худшем случае, так что
/// опрашивать можно каждый такт.
final class SpaceWatch {
    private typealias MainConnFn = @convention(c) () -> Int32
    private typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64

    private let cid: Int32
    private let activeSpace: ActiveSpaceFn?

    init() {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        let mc = dlsym(sky, "CGSMainConnectionID").map { unsafeBitCast($0, to: MainConnFn.self) }
        activeSpace = dlsym(sky, "CGSGetActiveSpace").map { unsafeBitCast($0, to: ActiveSpaceFn.self) }
        cid = mc?() ?? 0
    }

    var available: Bool { activeSpace != nil }

    /// 0, если функция недоступна — тогда смена пространства просто не ловится.
    func current() -> UInt64 { activeSpace?(cid) ?? 0 }

    // ── Заглянуть на соседние столы ──────────────────────────────────────────
    // Mission Control показывает живые миниатюры каждого стола, значит данные
    // есть и система умеет их отрисовать. Добирается до них Dock приватным
    // путём: список столов и их окон из SkyLight, содержимое —
    // `CGSHWCaptureWindowList`, та же функция, что рисует те миниатюры.
    //
    // Из процесса без разрешения на запись экрана она не отказывает, а молча
    // отдаёт пустой массив вместо картинки, причём даже для окон активного
    // стола. Поэтому проверять её можно только отсюда, из демона: у CLI,
    // запущенного из терминала, права принадлежат терминалу.

    private typealias CopyDisplaySpacesFn = @convention(c) (Int32) -> CFArray?
    private typealias CopyWindowsFn = @convention(c) (Int32, UInt32, CFArray, UInt32,
                                                      UnsafeMutablePointer<UInt64>,
                                                      UnsafeMutablePointer<UInt64>) -> CFArray?
    private typealias HWCaptureFn = @convention(c) (Int32, UnsafePointer<UInt32>, UInt32, UInt32) -> CFArray?

    /// Все столы по дисплеям, в порядке их расположения.
    func spaces() -> [(display: String, ids: [UInt64])] {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        guard let f = dlsym(sky, "CGSCopyManagedDisplaySpaces").map({ unsafeBitCast($0, to: CopyDisplaySpacesFn.self) }),
              let raw = f(cid) as? [[String: Any]] else { return [] }
        return raw.map { d in
            let ids = (d["Spaces"] as? [[String: Any]] ?? []).compactMap { $0["id64"] as? UInt64 }
            return (display: (d["Display Identifier"] as? String) ?? "?", ids: ids)
        }
    }

    /// Номера окон на указанном столе, сверху вниз по z-порядку.
    func windows(on space: UInt64) -> [UInt32] {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        guard let f = dlsym(sky, "CGSCopyWindowsWithOptionsAndTags").map({ unsafeBitCast($0, to: CopyWindowsFn.self) })
        else { return [] }
        var setTags: UInt64 = 0, clearTags: UInt64 = 0
        return f(cid, 0, [space] as CFArray, 2, &setTags, &clearTags) as? [UInt32] ?? []
    }

    /// Содержимое окна, даже если оно на неактивном столе. nil — система не
    /// отдала картинку.
    func capture(window: UInt32) -> CGImage? {
        let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW)
        guard let f = dlsym(sky, "CGSHWCaptureWindowList").map({ unsafeBitCast($0, to: HWCaptureFn.self) })
        else { return nil }
        var one = window
        // 0x0200 — снимать в номинальном разрешении, 0x0800 — не обрезать по
        // видимой области: окно на другом столе целиком за границей экрана.
        return (f(cid, &one, 1, 0x0200 | 0x0800) as? [CGImage])?.first
    }
}

/// Разведка: перечислить столы и посмотреть, отдаёт ли система содержимое окон
/// на тех из них, где мы сейчас не находимся.
func reportSpaces(_ watch: SpaceWatch) {
    let active = watch.current()
    let started = Date()
    log("── разведка столов ──")
    for d in watch.spaces() {
        log("  дисплей \(d.display): столов \(d.ids.count)")
        for sid in d.ids {
            let wins = watch.windows(on: sid)
            var got = 0, empty = 0, biggest = 0
            var biggestLuma: Double? = nil
            var sizes: [String] = []
            for w in wins.prefix(20) {
                guard let img = watch.capture(window: w) else { empty += 1; continue }
                got += 1
                let area = img.width * img.height
                if sizes.count < 4 { sizes.append("\(img.width)x\(img.height)") }
                if area > biggest, let l = imageLuma(img) { biggest = area; biggestLuma = l }
            }
            log(String(format: "    стол %d%@: окон %d, снято %d, пусто %d; крупнейшее %@ светлота %@%@",
                       Int(sid), sid == active ? " (активный)" : "",
                       wins.count, got, empty,
                       biggest > 0 ? "\(biggest)px" : "—",
                       biggestLuma.map { String(format: "%.3f", $0) } ?? "—",
                       sizes.isEmpty ? "" : "  [\(sizes.joined(separator: ", "))]"))
        }
    }
    // Цена вопроса: если опрашивать столы регулярно, она войдёт в постоянный
    // расход демона, и тогда решать, делать это по таймеру или только по
    // событию жеста.
    log(String(format: "── конец разведки, всё заняло %.0f мс ──", Date().timeIntervalSince(started) * 1000))
}

/// Воспринимаемая светлота готовой картинки — та же шкала, что у кадров экрана.
func imageLuma(_ image: CGImage, width: Int = 64, height: Int = 40) -> Double? {
    var buf = [UInt8](repeating: 0, count: width * height * 4)
    guard let ctx = CGContext(data: &buf, width: width, height: height, bitsPerComponent: 8,
                              bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var sum = 0.0
    for i in stride(from: 0, to: buf.count, by: 4) {
        sum += 0.2126 * linearLUT[Int(buf[i])]
             + 0.7152 * linearLUT[Int(buf[i + 1])]
             + 0.0722 * linearLUT[Int(buf[i + 2])]
    }
    let mean = sum / Double(width * height)
    return pow(max(0, min(1, mean)), 1.0 / 2.2)
}

/// Bundle id приложения на переднем плане. NSWorkspace не требует никаких
/// разрешений — в отличие от AppleScript, которому нужен Automation.
func frontmostBundleID() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
}

// ─────────────────────────────────────────────────────────────────────────────
// Перехват родных клавиш яркости
// ─────────────────────────────────────────────────────────────────────────────

/// Что tap'у разрешено проглатывать прямо сейчас. Обновляется контуром на
/// каждом такте, читается из обработчика события — отсюда и лок.
final class TapState: @unchecked Sendable {
    private let lock = NSLock()
    private var atCeiling = false
    private var boostActive = false
    private var disabled = false

    func update(atCeiling: Bool, boostActive: Bool) {
        lock.lock(); self.atCeiling = atCeiling; self.boostActive = boostActive; lock.unlock()
    }

    /// Проглатываем только там, где система всё равно ничего полезного не
    /// сделает: «ярче» на упёртой в потолок подсветке и обе клавиши внутри
    /// буста. Всё остальное пропускаем — это штатная регулировка и её HUD.
    func shouldSwallow(up: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if boostActive { return true }
        return up && atCeiling
    }

    func markDisabled() { lock.lock(); disabled = true; lock.unlock() }
    func takeDisabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let d = disabled; disabled = false; return d
    }
}

/// Накопленные нажатия: обработчик только складывает их сюда, всю работу
/// делает контур. Держать логику в обработчике нельзя — если он задумается,
/// macOS отключит tap по таймауту.
final class KeyIntent: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = 0
    func add(_ n: Int) { lock.lock(); pending += n; lock.unlock() }
    func take() -> Int { lock.lock(); defer { lock.unlock() }; let p = pending; pending = 0; return p }
}

/// Аккорд «ярче + тусклее одновременно» — выключатель адаптации.
///
/// Клавиши приходят по одной, поэтому аккорд опознаётся только на второй:
/// первая к этому моменту уже ушла в систему. Зато пока обе зажаты, все
/// события по ним глотаем, чтобы автоповтор не дёргал яркость.
final class ChordState: @unchecked Sendable {
    private let lock = NSLock()
    private var upHeld = false
    private var downHeld = false
    private var upAt = Date.distantPast
    private var downAt = Date.distantPast

    /// Момент, когда обе клавиши оказались зажаты. Отсюда отсчитывается
    /// удержание: аккорд засчитывается не по факту двух нажатий, а только если
    /// их подержали вместе. Иначе его слишком легко задеть, подкручивая яркость
    /// вверх-вниз — за сегодня так вышло дважды.
    private var bothSince: Date? = nil
    /// Обе побывали зажаты — глотаем события по ним до полного отпускания,
    /// чтобы автоповтору некуда было разогнаться.
    private var engaged = false
    private var matured = false
    private var pendingCancel = false

    func note(up: Bool, isDown: Bool, window: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if isDown {
            // Автоповтор шлёт нажатие повторно — момент фиксируем только на
            // переходе «не зажата → зажата».
            if up {
                if !upHeld { upHeld = true; upAt = now }
            } else {
                if !downHeld { downHeld = true; downAt = now }
            }
            if upHeld, downHeld, bothSince == nil, !matured,
               abs(upAt.timeIntervalSince(downAt)) < window {
                bothSince = now
                engaged = true
            }
        } else {
            if up { upHeld = false } else { downHeld = false }
            if !upHeld || !downHeld {
                // Отпустили раньше, чем аккорд созрел: команды не было, это
                // обычная подкрутка. Просим контур вернуть яркость как было.
                if bothSince != nil, !matured { pendingCancel = true }
                bothSince = nil
            }
            if !upHeld, !downHeld {
                engaged = false
                matured = false
            }
        }
    }

    /// Обе побывали зажаты и ещё не отпущены до конца — события наши.
    var held: Bool { lock.lock(); defer { lock.unlock() }; return engaged }

    /// Зажата хоть одна клавиша яркости. По переходу false→true контур
    /// запоминает яркость, чтобы было куда откатывать.
    var anyHeld: Bool { lock.lock(); defer { lock.unlock() }; return upHeld || downHeld }

    /// true ровно один раз — когда обе продержались вместе не меньше minHold.
    func matureIfReady(minHold: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let since = bothSince, !matured,
              Date().timeIntervalSince(since) >= minHold else { return false }
        matured = true
        return true
    }

    /// true один раз, если обе были зажаты, но их отпустили до созревания.
    func takeCancel() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let c = pendingCancel; pendingCancel = false; return c
    }
}
final class KeyPassState: @unchecked Sendable {
    private let lock = NSLock()
    private var swallowedUpKey = false
    private var swallowedDownKey = false

    func recordDown(up: Bool, swallowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        if up { swallowedUpKey = swallowed } else { swallowedDownKey = swallowed }
    }

    func swallowedDown(up: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return up ? swallowedUpKey : swallowedDownKey
    }
}

/// Трассировка событий клавиш яркости. Обработчик события должен быть быстрым,
/// иначе macOS отключит tap, поэтому он только складывает записи сюда, а пишет
/// их в лог уже контур.
final class KeyTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var enabled = false

    func add(_ s: String) {
        guard enabled else { return }
        lock.lock()
        if lines.count < 200 { lines.append(s) }
        lock.unlock()
    }

    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let l = lines; lines = []; return l
    }
}

let keyTrace = KeyTrace()

/// Наблюдение за типами событий: только для разбора, всё пропускается насквозь.
final class EventTraceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set(_ v: Bool) { lock.lock(); on = v; lock.unlock() }
    var enabled: Bool { lock.lock(); defer { lock.unlock() }; return on }
}
let eventTrace = EventTraceFlag()

/// Момент последнего жеста на трекпаде.
///
/// Свайп смены рабочего стола сыплет событиями типа 29 с того мгновения, как
/// пальцы поехали, — то есть заранее, до анимации. Номер пространства для этого
/// не годится: он меняется уже в конце перехода, когда полосы нарисованы.
/// Когда в последний раз трогали устройство ввода. Один и тот же приём для
/// трекпада и для клавиш яркости: обработчик только отмечает время, решение
/// принимает контур.
final class TouchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    func touch() { lock.lock(); last = Date(); lock.unlock() }
    func secondsSince() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

let gestureClock = TouchClock()

/// Последнее событие клавиш яркости — включая те, что мы пропускаем в систему.
/// Приходит раньше, чем система успевает довести подсветку, и это единственный
/// способ убрать руки с яркости ДО того, как человек увидит борьбу.
let keysClock = TouchClock()

private let gestureTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        gestureTapDisabled.set(true)
        return Unmanaged.passUnretained(event)
    }
    gestureClock.touch()
    return Unmanaged.passUnretained(event)
}

final class BoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    func set(_ x: Bool) { lock.lock(); v = x; lock.unlock() }
    func take() -> Bool { lock.lock(); defer { lock.unlock() }; let x = v; v = false; return x }
}
let gestureTapDisabled = BoolFlag()

/// Перехватчик жестов. Режим только для прослушивания: он физически не может
/// ничего заблокировать, в отличие от перехвата клавиш, и нужен лишь чтобы
/// узнать момент начала жеста.
final class GestureTap {
    private var tap: CFMachPort?
    private var lastAttempt = Date.distantPast
    private(set) var active = false

    @discardableResult
    func ensureRunning() -> Bool {
        if let tap, CGEvent.tapIsEnabled(tap: tap), !gestureTapDisabled.take() { return true }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true); if CGEvent.tapIsEnabled(tap: tap) { return true } }

        guard Date().timeIntervalSince(lastAttempt) > 30 else { return active }
        lastAttempt = Date()
        guard AXIsProcessTrusted() else { active = false; return false }

        var mask: CGEventMask = 0
        for t in [NSEvent.EventType.gesture, .swipe, .magnify, .smartMagnify, .scrollWheel] {
            mask |= CGEventMask(1 << t.rawValue)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .listenOnly, eventsOfInterest: mask,
                                        callback: gestureTapCallback, userInfo: nil) else {
            log("перехват жестов: не удалось создать event tap")
            active = false
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        active = true
        log("перехват жестов включён — съём глушится на время жестов трекпада")
        return true
    }
}

let tapState = TapState()
let keyIntent = KeyIntent()
let chordState = ChordState()
let keyPassState = KeyPassState()

// Подтип системного события для медиа-клавиш и коды яркости из IOKit.
private let systemDefinedSubtype: Int16 = 8
private let nxKeyBrightnessUp = 2
private let nxKeyBrightnessDown = 3

private let brightnessTapCallback: CGEventTapCallBack = { _, type, event, _ in
    // macOS отключает tap, если обработчик не уложился в отведённое время.
    // Само по себе это не ошибка — надо просто включить его заново.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tapState.markDisabled()
        return nil
    }
    if eventTrace.enabled, type.rawValue != 14 {
        let sub = NSEvent(cgEvent: event)?.subtype.rawValue
        keyTrace.add("событие тип=\(type.rawValue)\(sub.map { " подтип=\($0)" } ?? "")")
        return Unmanaged.passUnretained(event)
    }

    guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == systemDefinedSubtype else {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = Int((ns.data1 & 0xFFFF_0000) >> 16)
    guard keyCode == nxKeyBrightnessUp || keyCode == nxKeyBrightnessDown else {
        return Unmanaged.passUnretained(event)
    }
    let isUp = keyCode == nxKeyBrightnessUp
    let keyDown = ((ns.data1 & 0x0000_FF00) >> 8) == 0x0A

    // Отмечаем и нажатие, и отпускание, и автоповтор, и те события, что уйдут
    // в систему нетронутыми: контуру важен сам факт, что рука на яркости.
    keysClock.touch()

    chordState.note(up: isUp, isDown: keyDown, window: 0.4)

    // Отпускание всегда повторяет судьбу своего нажатия — иначе система
    // считает клавишу зажатой и повторяет её до упора.
    guard keyDown else {
        let sw = keyPassState.swallowedDown(up: isUp)
        keyTrace.add("\(isUp ? "ЯРЧЕ " : "ТУСКЛ") ↑  \(sw ? "глотаю" : "пропускаю")  аккорд=\(chordState.held ? "да" : "нет")")
        return sw ? nil : Unmanaged.passUnretained(event)
    }

    let swallow = chordState.held || tapState.shouldSwallow(up: isUp)
    keyPassState.recordDown(up: isUp, swallowed: swallow)
    keyTrace.add("\(isUp ? "ЯРЧЕ " : "ТУСКЛ") ↓  \(swallow ? "глотаю" : "пропускаю")  аккорд=\(chordState.held ? "да" : "нет")")
    guard swallow else { return Unmanaged.passUnretained(event) }

    // Шаг буста считаем только если это не аккорд: аккорд про другое.
    if !chordState.held { keyIntent.add(isUp ? 1 : -1) }
    return nil
}

/// Перехват клавиш яркости. Без разрешения Accessibility tap не создаётся —
/// это не ошибка, просто буст останется доступен только из CLI.
final class BrightnessKeyTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var lastAttempt = Date.distantPast
    private(set) var active = false

    var isTrusted: Bool { AXIsProcessTrusted() }

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Пытается поднять tap. Возвращает true, если он живой.
    @discardableResult
    func ensureRunning() -> Bool {
        if active, let tap, CGEvent.tapIsEnabled(tap: tap) { return true }

        if let tap, tapState.takeDisabled() || !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if CGEvent.tapIsEnabled(tap: tap) {
                log("перехват клавиш: tap был отключён системой, включил заново")
                return true
            }
        }

        // Пересоздание пробуем не чаще раза в 30с, чтобы не молотить впустую,
        // пока разрешение не выдано.
        guard Date().timeIntervalSince(lastAttempt) > 30 else { return active }
        lastAttempt = Date()

        guard AXIsProcessTrusted() else {
            if active { log("перехват клавиш: разрешение Accessibility отозвано") }
            active = false
            return false
        }

        var mask = CGEventMask(1 << NSEvent.EventType.systemDefined.rawValue)
        if eventTrace.enabled {
            for t in [NSEvent.EventType.gesture, .swipe, .scrollWheel, .magnify, .smartMagnify] {
                mask |= CGEventMask(1 << t.rawValue)
            }
        }
        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: brightnessTapCallback,
                                             userInfo: nil) else {
            log("перехват клавиш: не удалось создать event tap")
            active = false
            return false
        }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        tap = newTap
        source = src
        active = true
        log("перехват клавиш яркости включён")
        return true
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Яркость выше 100% на XDR-панели
// ─────────────────────────────────────────────────────────────────────────────

/// Крошечное окно с HDR-содержимым. Само по себе ничего не осветляет — его
/// единственная роль в том, чтобы macOS перевела панель в HDR-режим и открыла
/// запас яркости над SDR-белым.
///
/// Замерено на Liquid Retina XDR: без окна запас 1.2×, с окном выходит на
/// 2.667× (это 1600 нит против 600) примерно за секунду.
final class EDRTriggerView: MTKView, MTKViewDelegate {
    private var queue: MTLCommandQueue?

    init(value: Double) {
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                   device: MTLCreateSystemDefaultDevice())
        autoResizeDrawable = false
        drawableSize = CGSize(width: 1, height: 1)
        queue = device?.makeCommandQueue()
        delegate = self
        colorPixelFormat = .rgba16Float
        colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        // Значение выше 1.0 и есть HDR-содержимое: именно оно включает режим.
        clearColor = MTLClearColorMake(value, value, value, 1.0)
        preferredFramesPerSecond = 5
        if let l = layer as? CAMetalLayer {
            l.wantsExtendedDynamicRangeContent = true
            l.isOpaque = false
            l.pixelFormat = .rgba16Float
        }
    }

    required init(coder: NSCoder) { fatalError("не используется") }

    func draw(in view: MTKView) {
        guard let queue,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

/// Буст яркости выше 100%: HDR-режим плюс растяжение таблицы гаммы в
/// освободившийся запас.
///
/// Работает только в паре. Одна гамма без HDR-режима ничего не даст: значения
/// выше 1.0 просто обрежутся по белому, картинка потеряет света в highlights и
/// не станет ярче.
final class XDRBoost {
    private let display: CGDirectDisplayID
    private var window: NSWindow?

    /// Исходная таблица гаммы, снятая до вмешательства. Всё, что мы делаем, —
    /// это умножение её на коэффициент.
    private var baseRed = [CGGammaValue](repeating: 0, count: 256)
    private var baseGreen = [CGGammaValue](repeating: 0, count: 256)
    private var baseBlue = [CGGammaValue](repeating: 0, count: 256)
    private var haveBase = false

    private(set) var level: Double = 1.0

    init(display: CGDirectDisplayID) { self.display = display }

    var isActive: Bool { level > 1.0001 }

    /// Запас яркости, который система готова дать прямо сейчас. Больше 1.0
    /// означает, что панель в HDR-режиме.
    var headroom: Double {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display
        }
        return Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
    }

    private func captureBaseTable() -> Bool {
        var count: UInt32 = 0
        let rc = CGGetDisplayTransferByTable(display, 256, &baseRed, &baseGreen, &baseBlue, &count)
        guard rc == .success else {
            log("не удалось прочитать таблицу гаммы (ошибка \(rc.rawValue))")
            return false
        }
        haveBase = true
        return true
    }

    private func writeTable(factor: Double) {
        guard haveBase else { return }
        let f = CGGammaValue(factor)
        var r = baseRed.map { $0 * f }
        var g = baseGreen.map { $0 * f }
        var b = baseBlue.map { $0 * f }
        let rc = CGSetDisplayTransferByTable(display, 256, &r, &g, &b)
        if rc != .success { log("CGSetDisplayTransferByTable → ошибка \(rc.rawValue)") }
    }

    private func openTrigger() {
        guard window == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                         styleMask: [], backing: .buffered, defer: false)
        w.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        w.level = .screenSaver
        // Обязательно: созданное программно окно по умолчанию освобождает себя
        // при close(), и оставшаяся у нас ссылка даёт двойное освобождение —
        // падение в objc_release при опустошении autorelease pool.
        w.isReleasedWhenClosed = false
        w.isOpaque = false
        w.hasShadow = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.contentView = EDRTriggerView(value: 1.6)
        if let s = NSScreen.main {
            w.setFrameOrigin(CGPoint(x: s.frame.origin.x, y: s.frame.origin.y + s.frame.height - 1))
        }
        w.orderFrontRegardless()
        window = w
    }

    private func closeTrigger() {
        window?.close()
        window = nil
    }

    /// Выставляет уровень. 1.0 — выключено, всё остальное — во столько раз ярче
    /// обычного максимума.
    func set(_ newLevel: Double, maxLevel: Double) {
        let clamped = max(1.0, min(maxLevel, newLevel))
        if clamped <= 1.0001 {
            if isActive || window != nil {
                CGDisplayRestoreColorSyncSettings()
                closeTrigger()
                haveBase = false
                log("буст выключен")
            }
            level = 1.0
            return
        }

        if !isActive {
            // Базовую таблицу снимаем до включения: дальше все правки идут от неё.
            guard captureBaseTable() else { return }
            openTrigger()
            log(String(format: "буст включён: %.0f%%, жду HDR-режим", clamped * 100))
        }
        level = clamped
        writeTable(factor: clamped)
    }

    /// Гамма — общий ресурс: Night Shift, True Tone и смена цветового профиля
    /// перезаписывают её целиком, и наш множитель молча пропадает. Поэтому
    /// сверяем хвост таблицы с ожидаемым и при расхождении накладываем заново.
    func reapplyIfDrifted() {
        guard isActive, haveBase else { return }
        var r = [CGGammaValue](repeating: 0, count: 256)
        var g = r, b = r
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, 256, &r, &g, &b, &count) == .success,
              let last = r.last, let expected = baseRed.last else { return }
        let want = expected * CGGammaValue(level)
        if abs(last - want) > 0.01 {
            log(String(format: "таблица гаммы уехала (%.3f вместо %.3f) — накладываю буст заново", last, want))
            writeTable(factor: level)
        }
    }

    /// Снять всё и вернуть экран в исходное состояние.
    func disable() { set(1.0, maxLevel: 1.0) }
}

// ─────────────────────────────────────────────────────────────────────────────
// Источник светлоты для демона: два режима с одним интерфейсом
// ─────────────────────────────────────────────────────────────────────────────

/// Главное требование к обоим режимам: контур управления не должен блокироваться
/// на съёме. Раньше захват стоял прямо в цикле, каждый третий такт выходил вдвое
/// длиннее, и это читалось как биение на 10 Гц.
protocol LumaSource: AnyObject {
    /// Последняя посчитанная светлота; nil — кадров ещё не было.
    var luma: Double? { get }
    /// Сколько прошло с последнего кадра. Растёт, только если съём встал.
    var silence: TimeInterval { get }
    /// Сколько кадров доставлено. По нему отличают новый кадр от повтора того
    /// же самого: значение светлоты для этого не годится — два разных кадра
    /// могут дать одинаковое число, и «устоялось» сработало бы вхолостую.
    var frames: UInt64 { get }
    /// Забирает и очищает последнюю ошибку.
    func takeFailure() -> String?
    func start() async throws
    func stop() async
    /// Временно не снимать кадры, не разбирая машинерию захвата.
    func setSuspended(_ on: Bool)
}

/// Одиночные снимки в отдельной задаче.
///
/// Постоянной сессии захвата нет, поэтому macOS не показывает индикатор записи
/// экрана. Платим тем, что снимок стоит одинаково всегда: `SCStream` на
/// статичной картинке не присылает ничего, а здесь мы снимаем по расписанию
/// независимо от того, менялось что-то или нет.
final class ShotSampler: LumaSource, @unchecked Sendable {
    private let shooter: ScreenSampler
    private let interval: TimeInterval

    private let lock = NSLock()
    private var _luma: Double?
    private var _lastDelivery = Date.distantPast
    private var _frames: UInt64 = 0
    private var _failure: String?

    private var task: Task<Void, Never>?
    private var _suspended = false

    func setSuspended(_ on: Bool) { lock.lock(); _suspended = on; lock.unlock() }
    private var suspended: Bool { lock.lock(); defer { lock.unlock() }; return _suspended }

    init(width: Int, height: Int, fps: Double) {
        shooter = ScreenSampler(width: width, height: height)
        interval = 1.0 / max(0.1, fps)
    }

    var luma: Double? { lock.lock(); defer { lock.unlock() }; return _luma }

    var silence: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastDelivery)
    }

    var frames: UInt64 { lock.lock(); defer { lock.unlock() }; return _frames }

    func takeFailure() -> String? {
        lock.lock(); defer { lock.unlock() }
        let f = _failure; _failure = nil; return f
    }

    private func publish(_ value: Double) {
        lock.lock(); _luma = value; _lastDelivery = Date(); _frames &+= 1; lock.unlock()
    }

    private func publish(failure: String) {
        lock.lock(); _failure = failure; lock.unlock()
    }

    func start() async throws {
        await stop()
        // Первый снимок делаем синхронно: если разрешения нет, демон должен
        // узнать об этом сразу, а не через пять секунд молчания.
        publish(try await shooter.luma())

        let shooter = self.shooter
        let interval = self.interval
        task = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard let self else { return }
                // Во время анимации смены рабочего стола съём рвёт кадр:
                // одиночный скриншот заставляет оконный сервер собрать
                // внеочередной кадр ровно тогда, когда он рисует переход.
                if self.suspended { continue }
                do {
                    self.publish(try await shooter.luma())
                } catch {
                    shooter.invalidate()
                    self.publish(failure: error.localizedDescription)
                    return
                }
            }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Непрерывный поток кадров — то, чем пользуется демон
// ─────────────────────────────────────────────────────────────────────────────

/// Одноразовый `SCScreenshotManager.captureImage` стоит ~35 мс на вызов, и он
/// стоял прямо в контуре управления: каждый третий такт выходил вдвое длиннее
/// остальных, что читалось как биение на 10 Гц. Поток отдаёт кадры сам, в своей
/// очереди, а контур только забирает последнее посчитанное значение и не
/// блокируется никогда.
///
/// Вдобавок поток не присылает картинку, когда она не изменилась, — на
/// статичном экране съём почти ничего не стоит.
final class LiveSampler: NSObject, LumaSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let width: Int
    private let height: Int
    private let fps: Double

    private let lock = NSLock()
    private var _luma: Double?
    private var _lastDelivery = Date.distantPast
    private var _frames: UInt64 = 0
    private var _failure: String?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.geforester.adaptive-brightness.capture",
                                      qos: .userInitiated)

    init(width: Int, height: Int, fps: Double) {
        self.width = width
        self.height = height
        self.fps = max(1, fps)
        super.init()
    }

    /// Последняя посчитанная светлота; nil — кадров ещё не было.
    var luma: Double? { lock.lock(); defer { lock.unlock() }; return _luma }

    /// Сколько прошло с последнего кадра любого рода. Растёт только если поток
    /// действительно встал: статичный экран всё равно шлёт кадры со статусом
    /// «без изменений», и они здесь учитываются.
    var silence: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(_lastDelivery)
    }

    var frames: UInt64 { lock.lock(); defer { lock.unlock() }; return _frames }

    /// Забирает и очищает последнюю ошибку потока.
    func takeFailure() -> String? {
        lock.lock(); defer { lock.unlock() }
        let f = _failure; _failure = nil; return f
    }

    func start() async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw NSError(domain: "adaptive-brightness", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "нет доступных дисплеев"])
        }
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.showsCursor = false
        cfg.capturesAudio = false
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 3
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))

        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                         configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        noteStreamStarted()
        stream = s
    }

    /// Синхронная обёртка: NSLock нельзя брать прямо из async-контекста.
    private func noteStreamStarted() {
        lock.lock(); _lastDelivery = Date(); _failure = nil; lock.unlock()
    }

    /// У потока приостановки нет: его пришлось бы останавливать и поднимать
    /// заново, что дороже самой проблемы. В режиме `stream` полосы на смене
    /// рабочего стола остаются — это одна из причин, почему он не по умолчанию.
    func setSuspended(_ on: Bool) {}

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        lock.lock(); _lastDelivery = Date(); lock.unlock()

        // Кадр без изменений приходит пустым: светлоты он не несёт, прежнее
        // значение остаётся в силе.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = sb.imageBuffer else { return }

        let l = LiveSampler.perceivedLuma(pixels)
        lock.lock(); _luma = l; _frames &+= 1; lock.unlock()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock(); _failure = error.localizedDescription; lock.unlock()
    }

    /// Та же метрика, что у одноразового сэмплера, но по BGRA-буферу потока.
    static func perceivedLuma(_ px: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return 0 }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        guard w > 0, h > 0 else { return 0 }
        let rowBytes = CVPixelBufferGetBytesPerRow(px)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for y in 0..<h {
            let row = p + y * rowBytes
            for x in 0..<w {
                let i = x * 4                       // BGRA
                sum += 0.0722 * linearLUT[Int(row[i])]
                     + 0.7152 * linearLUT[Int(row[i + 1])]
                     + 0.2126 * linearLUT[Int(row[i + 2])]
            }
        }
        return pow(max(0, min(1, sum / Double(w * h))), 1.0 / 2.2)
    }
}

/// Состояние, доступное обработчику SIGTERM. launchd шлёт SIGTERM при kickstart
/// и bootout, а state.json пишется только по приходу к цели — без сохранения
/// здесь перезапуск посреди хода оставлял бы в файле устаревший lastWritten, и
/// на следующем старте демон принимал бы расхождение за ручную правку и замирал
/// на случайной яркости.
final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State?
    func set(_ s: State) { lock.lock(); state = s; lock.unlock() }
    func snapshot() -> State? { lock.lock(); defer { lock.unlock() }; return state }
}

let liveState = StateBox()

// ─────────────────────────────────────────────────────────────────────────────
// Модель яркости
// ─────────────────────────────────────────────────────────────────────────────

func normalizedLuma(_ luma: Double, _ c: Config) -> Double {
    let span = max(1e-6, c.lightPoint - c.darkPoint)
    return max(0, min(1, (luma - c.darkPoint) / span))
}

/// target = baseline × span^(L_now − L_baseline), зажатый в [min, max].
func targetBrightness(luma: Double, state: State, config c: Config) -> Double {
    let now = normalizedLuma(luma, c)
    let ref = normalizedLuma(state.baselineLuma, c)
    let factor = pow(c.span, now - ref)
    return max(c.minBrightness, min(c.maxBrightness, state.baseline * factor))
}

// ─────────────────────────────────────────────────────────────────────────────
// Логирование
// ─────────────────────────────────────────────────────────────────────────────

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

var logToFile = false

func log(_ message: String) {
    let line = "\(logFormatter.string(from: Date()))  \(message)"
    print(line)
    fflush(stdout)
    guard logToFile else { return }
    if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
       let size = attrs[.size] as? UInt64, size > 1_000_000 {
        // Простая ротация: держим только последнюю половину.
        if let data = try? Data(contentsOf: logURL) {
            try? data.suffix(500_000).write(to: logURL, options: .atomic)
        }
    }
    if let data = (line + "\n").data(using: .utf8) {
        if let fh = try? FileHandle(forWritingTo: logURL) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: logURL)
        }
    }
}

func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

// ─────────────────────────────────────────────────────────────────────────────
// Состояние сессии: не работаем на спящем/заблокированном экране
// ─────────────────────────────────────────────────────────────────────────────

func screenIsUsable(_ display: CGDirectDisplayID) -> Bool {
    if CGDisplayIsAsleep(display) != 0 { return false }
    if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
       let locked = session["CGSSessionScreenIsLocked"] as? Bool, locked { return false }
    return true
}

// ─────────────────────────────────────────────────────────────────────────────
// Основной цикл
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
func runDaemon(dryRun: Bool, singleShot: Bool) async {
    ensureDirs()
    let config = Config.load()
    let display = CGMainDisplayID()

    guard let backlight = Backlight() else {
        log("ОШИБКА: не удалось подключиться к DisplayServices — управление подсветкой недоступно")
        exit(1)
    }
    guard let initialBrightness = backlight.read(display) else {
        log("ОШИБКА: не удалось прочитать текущую яркость")
        exit(1)
    }

    let useStream = config.captureMode.lowercased() == "stream"
    let sampler: LumaSource = useStream
        ? LiveSampler(width: config.sampleWidth, height: config.sampleHeight, fps: config.captureHz)
        : ShotSampler(width: config.sampleWidth, height: config.sampleHeight, fps: config.captureHz)
    // Поднимаем съём, не сдаваясь с первой попытки: на входе в систему кадры
    // начинают идти не сразу. baseline бессмыслен без светлоты, при которой он
    // задан, поэтому до первого кадра дальше не идём.
    let startDeadline = Date().addingTimeInterval(max(0, config.startupGrace))
    var firstLuma: Double? = nil
    var lastStartError = "кадров нет"
    var warnedAboutStart = false

    while firstLuma == nil {
        do {
            try await sampler.start()
        } catch {
            lastStartError = error.localizedDescription
        }

        var waited = 0.0
        while waited < 3, firstLuma == nil {
            if let l = sampler.luma { firstLuma = l; break }
            if let f = sampler.takeFailure() { lastStartError = f; break }
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        if firstLuma != nil { break }

        if Date() >= startDeadline {
            log("ОШИБКА захвата экрана: \(lastStartError)")
            log("За \(Int(config.startupGrace))с кадр так и не пришёл. Скорее всего не выдано " +
                "разрешение Screen Recording. Смотри INTERNALS.md, раздел «Разрешения».")
            exit(2)
        }
        if !warnedAboutStart {
            warnedAboutStart = true
            log("съём пока не отдаёт кадры (\(lastStartError)) — продолжаю пробовать до \(Int(config.startupGrace))с; " +
                "сразу после входа в систему это нормально")
        }
        await sampler.stop()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    var smoothedLuma = firstLuma ?? 0
    if warnedAboutStart { log("съём пошёл, светлота \(String(format: "%.3f", smoothedLuma))") }

    let hadState = State.load() != nil
    var state = State.load() ?? State(baseline: initialBrightness,
                                      baselineLuma: smoothedLuma,
                                      lastWritten: initialBrightness,
                                      enabled: true,
                                      holdLuma: nil)
    if !hadState {
        log("Стартовый baseline: \(pct(state.baseline)) при светлоте \(String(format: "%.3f", state.baselineLuma))")
        state.save()
    }

    // launchd шлёт SIGTERM при kickstart и bootout. Сохраняем состояние, иначе
    // в файле останется значение с последнего прихода к цели.
    liveState.set(state)
    EnableChannel.write(state.enabled)
    let signalQueue = DispatchQueue(label: "com.geforester.adaptive-brightness.signal")
    signal(SIGTERM, SIG_IGN)
    let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
    termSource.setEventHandler {
        if !dryRun, let s = liveState.snapshot() { s.save() }
        log("SIGTERM — состояние сохранено, выхожу")
        exit(0)
    }
    termSource.resume()

    let dtControl = 1.0 / max(1, config.controlHz)
    // Потолок на шаг времени. После долгой паузы (спящий экран, перегруженная
    // система) честный dt дал бы один гигантский шаг — это выглядело бы скачком.
    // Лучше доехать за пару тактов.
    let maxTick = 0.1
    // Собственная частота пружины. При критическом демпфировании путь пройден
    // на ~98% к моменту omega·t ≈ 6 — отсюда пересчёт из travelTime.
    let omega = 6.0 / max(0.05, config.travelTime)

    if config.legacyTauBrightness {
        log("ВНИМАНИЕ: в конфиге есть tauBrightness — прежний контур первого порядка убран, " +
            "ключ игнорируется. Скорость хода теперь задаёт travelTime (сек до прихода), сейчас \(config.travelTime).")
    }

    log("Запуск. control=\(Int(config.controlHz))Гц " +
        "capture=\(Int(config.captureHz))Гц/\(useStream ? "stream" : "shot") " +
        "tauLuma=\(config.tauLuma)s travel=\(config.travelTime)s span=\(config.span) " +
        "dark=\(config.darkPoint) light=\(config.lightPoint) " +
        "range=[\(pct(config.minBrightness)), \(pct(config.maxBrightness))]\(dryRun ? " [DRY RUN]" : "")")

    var current = initialBrightness
    var velocity = 0.0
    var lastTick = Date()

    // Пауза после ручной правки: пока контент не сменился заметно, выставленная
    // рукой яркость и есть правильная — лезть туда не за чем.
    var holding = state.holdLuma != nil
    var holdLuma = state.holdLuma ?? smoothedLuma
    var manualPending = false
    var manualAt = Date.distantPast

    // Начало текущего хода — ради строчки в логе «откуда и за сколько».
    var moveFrom: Double? = nil
    var moveStarted = Date()
    // Сколько раз за ход реально записали подсветку. Ступеньки на глаз — это
    // вопрос о размере шага, а он считается отсюда, а не прикидывается.
    var moveWrites = 0

    // Пауза на время игры: яркость не трогаем вообще и съём кадров глушим —
    // он стоит около 20% одного ядра, а игре эти такты нужнее.
    let gameMode = GameModeWatch()
    if config.pauseOnGameMode && !gameMode.available {
        log("ВНИМАНИЕ: состояние Game Mode недоступно, пауза по нему работать не будет")
    }
    let boost = XDRBoost(display: display)
    keyTrace.enabled = config.traceKeys || config.traceEvents
    eventTrace.set(config.traceEvents)
    let keyTap = BrightnessKeyTap()
    if config.nativeKeysBoost && config.maxBoost > 1.0 {
        if !keyTap.isTrusted {
            log("перехват клавиш яркости требует разрешения Accessibility — запрашиваю")
            keyTap.requestPermission()
        }
        keyTap.ensureRunning()
    }
    var desiredBoost = 1.0
    var preBoostBrightness = initialBrightness
    var boostTick = 0
    let gestureTap = GestureTap()
    if config.gestureSettle > 0 {
        gestureTap.ensureRunning()
    }
    var gestureSuspended = false
    let spaceWatch = SpaceWatch()
    if config.probeSpaces { reportSpaces(spaceWatch) }
    if !spaceWatch.available {
        log("ВНИМАНИЕ: номер рабочего стола недоступен — съём на смене десктопа глушиться не будет")
    }
    var lastSpace = spaceWatch.current()
    var spaceSettleUntil = Date.distantPast
    var spaceGraceUntil = Date.distantPast
    var spaceSuspended = false
    var screenWasUsable = true
    var wakeSettleUntil = Date.distantPast
    // Снимок на момент начала серии нажатий клавиш яркости. Автоповтор успевает
    // угнать яркость к упору, пока человек тянется ко второй клавише аккорда,
    // поэтому откатывать надо сюда, а не к последнему записанному значению.
    var keysWereHeld = false
    var preKeys: (brightness: Double, baseline: Double, baselineLuma: Double)? = nil
    // Одной записи для отката мало: события клавиш, уже стоящие в очереди
    // системы, долетают после неё и снова уводят яркость. Держим значение,
    // пока клавиши зажаты, и полсекунды после отпускания.
    var chordRestore: Double? = nil
    var chordRestoreUntil = Date.distantPast
    var captureDown = false
    var lastRestart = Date.distantPast
    var paused = false

    // ── Ручная правка клавишами ──────────────────────────────────────────────
    // Пока серия идёт, демон нем: не пишет подсветку и не трогает lastWritten.
    // Это не оптимизация, а условие корректности. Стоит ему записать своё
    // значение — и расхождение «записал vs стоит», единственный след правки,
    // исчезает вместе с ней: следующий такт видит ровно то, что сам же и
    // выставил, и правка пропадает бесследно. Так и терялись тапы.
    var keysSeries = false
    /// lastWritten на момент начала серии — с ним сверяем итог, а не с тем, что
    /// демон успел бы записать по дороге.
    var keysSeriesWritten = 0.0
    var keysSeriesActual = 0.0
    var keysSeriesStill = Date()
    var keysSeriesStart = Date()

    // Светлота после правки ещё не установилась: сглаженная догоняет сырую.
    // Пока догоняет, точка отсчёта дописывается свежей светлотой.
    var lumaSettling = false
    var lumaSettlingUntil = Date.distantPast

    // ── Ожидание устоявшейся светлоты ────────────────────────────────────────
    // После перехода (жест, смена стола) светлоту берём не первую попавшуюся, а
    // устоявшуюся: пока анимация идёт, кадры показывают смесь старого и нового,
    // и тронувшись по такому кадру, демон едет второй раз — переход выходит
    // двухступенчатым.
    //
    // Ждать этого НЕЛЬЗЯ блокирующе. Первая версия крутила `await` прямо в
    // такте, и пока она ждала, демон не делал ничего — ни ведения, ни реакции
    // на жесты. При коротком `gestureSettle` заглушка снимается от малейшей
    // паузы в движении пальцев, цикл тут же уходил в полуторасекундное
    // ожидание, и так по кругу: снаружи это выглядело как залипание.
    var steadyWait = false
    var steadyUntil = Date.distantPast
    var steadyPrev: Double? = nil
    var steadySeen: UInt64 = 0

    /// Открыть ожидание устоявшейся светлоты после перехода.
    func awaitSteady(_ timeout: Double = 1.5) {
        steadyWait = true
        steadyUntil = Date().addingTimeInterval(timeout)
        steadyPrev = nil
        steadySeen = sampler.frames
    }
    var pauseBrightness = initialBrightness
    var pauseCheckTick = 0
    var pauseReason = ""

    /// Гасит ход и под трассировкой пишет, кто именно его прервал. Прерванный
    /// ход в лог не попадает — строка «вёл X → Y» печатается только по
    /// завершении, — и переход, разорванный надвое, выглядит в логе как один
    /// ход неизвестно откуда.
    func halt(_ reason: String) {
        if moveFrom != nil, config.traceEvents || config.traceKeys {
            log("  [ход] прерван на \(pct(current)): \(reason)")
        }
        velocity = 0
        moveFrom = nil
    }

    /// Принять выставленное рукой значение: ход гасим, значение становится
    /// точкой отсчёта при текущей светлоте, адаптация уходит в паузу до смены
    /// контента. Одна дорога для клавиш, Control Center и системного датчика.
    func acceptManual(_ value: Double) {
        velocity = 0
        current = value
        moveFrom = nil
        state.baseline = value
        state.baselineLuma = smoothedLuma
        state.lastWritten = value
        holding = true
        holdLuma = smoothedLuma
        state.holdLuma = smoothedLuma
        // Светлота могла не устояться — тогда точку отсчёта допишем, когда
        // сглаженная догонит сырую.
        lumaSettling = true
        lumaSettlingUntil = Date().addingTimeInterval(max(0, config.lumaSettleMax))
        state.save()
        liveState.set(state)
        manualPending = true
        manualAt = Date()
    }

    while true {
        try? await Task.sleep(nanoseconds: UInt64(dtControl * 1_000_000_000))

        // Реальный шаг времени, а не предполагаемый. Раньше пружина считала,
        // что прошло ровно 1/controlHz, и при любом подтормаживании цикла шла
        // во столько же раз медленнее заявленного.
        let tickNow = Date()
        let dt = min(max(tickNow.timeIntervalSince(lastTick), dtControl * 0.25), maxTick)
        lastTick = tickNow

        guard screenIsUsable(display) else {
            velocity = 0
            moveFrom = nil
            screenWasUsable = false
            continue
        }
        if !screenWasUsable {
            screenWasUsable = true
            wakeSettleUntil = Date().addingTimeInterval(max(0, config.wakeSettle))
            log(String(format: "экран проснулся — не трогаю яркость %.1fс, пока система доводит свой рамп",
                       max(0, config.wakeSettle)))
        }

        guard let actual = backlight.read(display) else { continue }
        boostTick &+= 1
        var frozenByGesture = false

        // ── Ручная серия на клавишах яркости ─────────────────────────────────
        // Открываем её по первому же событию клавиши — tap видит его раньше,
        // чем система успевает тронуть подсветку. Флаг поднимаем здесь, до
        // всех веток с `continue`: ниже по такту есть ветки, которые
        // синхронизируют lastWritten с прочитанным, и им нельзя дать стереть
        // след правки, пока серия не закрыта.
        if config.keySettle > 0 {
            if !keysSeries, keysClock.secondsSince() < config.keySettle {
                keysSeries = true
                keysSeriesWritten = state.lastWritten
                keysSeriesActual = actual
                keysSeriesStill = Date()
                keysSeriesStart = Date()
            }
            if keysSeries, abs(actual - keysSeriesActual) > 1e-4 {
                // Подсветка ещё едет — рамп системы не закончен.
                keysSeriesActual = actual
                keysSeriesStill = Date()
            }
        }

        // Серия нажатий — это одна правка, строку пишем по её затиханию.
        // Печатаем здесь, до всех веток с `continue`: раньше строка стояла в
        // самом низу такта, и пока шёл жест или пауза, цикл до неё не доходил
        // — правка появлялась в логе через секунды после того, как случилась,
        // рядом с чужими событиями. Разбирать такой лог невозможно.
        if manualPending, Date().timeIntervalSince(manualAt) > config.manualQuietPeriod {
            manualPending = false
            log(String(format: "ручная правка → baseline %@ при светлоте %.3f (norm %.2f); держу, пока контент не сменится",
                       pct(state.baseline), state.baselineLuma,
                       normalizedLuma(state.baselineLuma, config)))
            if singleShot { return }
        }

        // ── Жест на трекпаде ─────────────────────────────────────────────────
        // Пока пальцы на трекпаде и полсекунды после — не снимаем кадров.
        // Это единственный сигнал, приходящий ДО анимации перехода: номер
        // пространства меняется уже в конце, когда полосы нарисованы.
        if config.gestureSettle > 0 {
            if boostTick % 15 == 0 { gestureTap.ensureRunning() }
            let quiet = gestureClock.secondsSince()
            if quiet < config.gestureSettle {
                if !gestureSuspended {
                    gestureSuspended = true
                    sampler.setSuspended(true)
                    halt("жест на трекпаде")
                    if config.traceEvents || config.traceKeys { log("  [жест] съём заглушен") }
                }
                // Раньше здесь был continue — и пока рука лежала на трекпаде,
                // цикл не доходил ни до выключателя, ни до клавиш, ни до буста.
                // Глушим только съём и ведение, всё остальное работает.
                frozenByGesture = true
            } else if gestureSuspended {
                gestureSuspended = false
                sampler.setSuspended(false)
                // Контент за время жеста наверняка другой — светлоту возьмём
                // заново, без сглаживания от протухшей, но не первую
                // попавшуюся: заглушка отпускает через gestureSettle после
                // того, как убрали пальцы, а анимация к этому моменту ещё идёт.
                awaitSteady()
                if config.traceEvents || config.traceKeys { log("  [жест] отпущен, жду устоявшуюся светлоту") }
                lastTick = Date()
                continue
            }
        }

        // ── Смена рабочего стола ─────────────────────────────────────────────
        // Пока идёт анимация перехода, не снимаем кадров и не трогаем яркость:
        // запрос на захват в этот момент рвёт кадр вертикальными полосами.
        if config.spaceSettle > 0, spaceWatch.available {
            let now = spaceWatch.current()
            if now != lastSpace, config.traceEvents || config.traceKeys {
                log(String(format: "  [стол] номер %d → %d, отсрочка %@",
                           Int(lastSpace), Int(now),
                           Date() < spaceGraceUntil
                               ? String(format: "ещё действует (%.2fс)", spaceGraceUntil.timeIntervalSinceNow)
                               : "истекла — глушу съём"))
            }
            if now != lastSpace, Date() >= spaceGraceUntil {
                lastSpace = now
                spaceSettleUntil = Date().addingTimeInterval(config.spaceSettle)
                if !spaceSuspended {
                    spaceSuspended = true
                    sampler.setSuspended(true)
                }
                halt("смена рабочего стола")
            }
            if now != lastSpace { lastSpace = now }
            if spaceSuspended {
                if Date() < spaceSettleUntil {
                    current = actual
                    if !keysSeries { state.lastWritten = actual }
                    continue
                }
                spaceSuspended = false
                sampler.setSuspended(false)
                // Светлота за время перехода протухла: контент другой.
                // Берём устоявшуюся, а не первую попавшуюся: пока анимация
                // доигрывает, кадры показывают смесь старого и нового.
                awaitSteady()
                lastTick = Date()
                continue
            }
        }

        if config.traceKeys || config.traceEvents {
            for line in keyTrace.drain() { log("  [события] \(line)") }
        }

        // Додерживаем откат после аккорда, пока долетают события клавиш.
        if let v = chordRestore {
            if Date() < chordRestoreUntil || chordState.anyHeld {
                if chordState.anyHeld { chordRestoreUntil = Date().addingTimeInterval(0.5) }
                if !dryRun, abs(actual - v) > 1e-4 { backlight.write(display, v) }
                // Аккорд правит яркость сам и сам знает, к чему её вернуть.
                // Открытую его же клавишами серию закрываем, иначе она сверит
                // откат с тем, что было до аккорда, и примет его за ручную
                // правку.
                keysSeries = false
                state.lastWritten = v
                current = v
                velocity = 0
                moveFrom = nil
                continue
            }
            chordRestore = nil
            state.lastWritten = v
            current = v
        }

        // Пока идёт рамп системы, молчим целиком: не пишем яркость и не считаем
        // её правки ручными — иначе baseline уедет на случайную точку рампа.
        if Date() < wakeSettleUntil {
            current = actual
            if !keysSeries { state.lastWritten = actual }
            velocity = 0
            moveFrom = nil
            continue
        }

        // ── Яркость выше 100% ────────────────────────────────────────────────
        // Пока буст включён, адаптив молчит: на таких яркостях он не нужен, да
        // и подсветка всё равно прижата к максимуму — регулировать нечем.
        // Выключатель могли дёрнуть снаружи командой `toggle`.
        if let want = EnableChannel.read(), want != state.enabled {
            state.enabled = want
            state.holdLuma = nil
            holding = false
            velocity = 0
            moveFrom = nil
            state.save()
            liveState.set(state)
            log(state.enabled ? "команда toggle → адаптация ВКЛЮЧЕНА" : "команда toggle → адаптация ВЫКЛЮЧЕНА")
            if state.enabled {
                do { try await sampler.start() } catch {}
                var w = 0.0
                while sampler.luma == nil, w < 3 { try? await Task.sleep(nanoseconds: 50_000_000); w += 0.05 }
                if let fresh = sampler.luma { smoothedLuma = fresh }
                state.baseline = actual
                state.baselineLuma = smoothedLuma
                state.lastWritten = actual
                current = actual
                state.save()
                lastTick = Date()
            } else {
                await sampler.stop()
            }
            continue
        }

        if let want = BoostChannel.read() { desiredBoost = want }

        if config.nativeKeysBoost && config.maxBoost > 1.0 {
            // Держим tap живым и сообщаем ему, что сейчас можно проглатывать.
            // Потолком считаем подсветку на максимуме: именно там системные
            // клавиши перестают что-либо делать и начинается наша зона.
            tapState.update(atCeiling: actual >= 0.999, boostActive: boost.isActive)
            if boostTick % 15 == 0 {
                let ok = keyTap.ensureRunning()
                TapStatusChannel.write(ok)
            }

            let heldNow = chordState.anyHeld
            if heldNow, !keysWereHeld {
                preKeys = (actual, state.baseline, state.baselineLuma)
            }
            keysWereHeld = heldNow

            if chordState.takeCancel(), let back = preKeys {
                // Обе клавиши были зажаты, но их отпустили до созревания —
                // команды не было. События мы проглотили, поэтому возвращаем
                // яркость к тому, что было до нажатий.
                log(String(format: "аккорд не созрел — возвращаю %@, какой была до нажатий",
                           pct(back.brightness)))
                chordRestore = back.brightness
                chordRestoreUntil = Date().addingTimeInterval(0.3)
                if !dryRun { backlight.write(display, back.brightness) }
                state.lastWritten = back.brightness
                state.baseline = back.baseline
                state.baselineLuma = back.baselineLuma
                current = back.brightness
                preKeys = nil
                _ = keyIntent.take()
                continue
            }

            if chordState.matureIfReady(minHold: config.chordHold) {
                state.enabled.toggle()
                state.holdLuma = nil
                holding = false
                velocity = 0
                moveFrom = nil
                // Первая клавиша аккорда успела уйти в систему, и её автоповтор
                // мог укатить яркость к упору. Возвращаем то, что было до всей
                // серии нажатий, вместе с прежней точкой отсчёта.
                let restore = preKeys ?? (actual, state.baseline, state.baselineLuma)
                log(String(format: "аккорд: яркость была %@, стала %@, откатываю на %@%@",
                           pct(preKeys?.brightness ?? actual), pct(actual), pct(restore.brightness),
                           preKeys == nil ? "  [снимка не было!]" : ""))
                chordRestore = restore.brightness
                chordRestoreUntil = Date().addingTimeInterval(0.5)
                if !dryRun { backlight.write(display, restore.brightness) }
                keysSeries = false
                state.lastWritten = restore.brightness
                state.baseline = restore.baseline
                state.baselineLuma = restore.baselineLuma
                current = restore.brightness
                preKeys = nil
                // Шаги, накопленные автоповтором, к бусту отношения не имеют.
                _ = keyIntent.take()
                state.save()
                liveState.set(state)
                EnableChannel.write(state.enabled)
                log(state.enabled
                    ? "аккорд «ярче+тусклее» → адаптация ВКЛЮЧЕНА"
                    : "аккорд «ярче+тусклее» → адаптация ВЫКЛЮЧЕНА, яркость оставляю тебе")
                if state.enabled {
                    // Светлота за время простоя протухла — берём свежий кадр.
                    do { try await sampler.start() } catch {
                        log("после включения съём не поднялся (\(error.localizedDescription))")
                    }
                    var w = 0.0
                    while sampler.luma == nil, w < 3 {
                        try? await Task.sleep(nanoseconds: 50_000_000); w += 0.05
                    }
                    if let fresh = sampler.luma { smoothedLuma = fresh }
                    // Точку отсчёта берём ту, что была до аккорда, но привязываем
                    // к свежей светлоте: за время простоя контент мог смениться.
                    state.baseline = state.lastWritten
                    state.baselineLuma = smoothedLuma
                    state.holdLuma = smoothedLuma
                    holding = true
                    state.save()
                    lastTick = Date()
                } else {
                    await sampler.stop()
                }
                continue
            }

            let steps = keyIntent.take()
            if steps != 0 {
                // Шаг 1/16 — тот же, что у системных клавиш, чтобы переход
                // через 100% не чувствовался ступенькой.
                let next = max(1.0, min(config.maxBoost, desiredBoost + Double(steps) / 16.0))
                if abs(next - desiredBoost) > 1e-6 {
                    desiredBoost = next
                    BoostChannel.write(desiredBoost)
                    log(String(format: "клавиши яркости → %.0f%%", desiredBoost * 100))
                }
            }
        }

        if desiredBoost > 1.0001 && config.maxBoost > 1.0 {
            if !boost.isActive {
                preBoostBrightness = actual
                velocity = 0
                moveFrom = nil
                await sampler.stop()
                log("буст запрошен (\(Int(desiredBoost * 100))%), яркость до него \(pct(actual))")
            }
            // Подсветку держим в потолке: выше неё добавляет только гамма.
            if abs(actual - 1.0) > 1e-4, !dryRun {
                backlight.write(display, 1.0)
            }
            state.lastWritten = 1.0
            boost.set(desiredBoost, maxLevel: config.maxBoost)
            if boostTick % 30 == 0 { boost.reapplyIfDrifted() }
            continue
        }

        if boost.isActive {
            boost.disable()
            // Выход из HDR-режима не мгновенный, и система в процессе может
            // сама переставить подсветку. Додерживаем нужное значение секунду:
            // иначе следующий такт прочитает чужую правку как ручную и сменит
            // baseline на случайное значение.
            for _ in 0..<20 {
                if !dryRun { backlight.write(display, preBoostBrightness) }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let settledBrightness = backlight.read(display) ?? preBoostBrightness
            // Серию, открытую клавишами внутри буста, закрываем здесь же и
            // молча. Иначе она доживёт до следующего такта и сверит
            // возвращённую яркость с потолком, на котором стоял буст: разница
            // огромная, и демон объявит ручную правку, которой не было, —
            // адаптация встанет до самой смены контента. Буст — отдельный
            // режим, а не новая точка отсчёта.
            keysSeries = false
            state.lastWritten = settledBrightness
            current = settledBrightness
            velocity = 0
            moveFrom = nil
            // Возвращаемся к прежней яркости и прежнему baseline: буст — это
            // отдельный режим, а не новая точка отсчёта для адаптива.
            do { try await sampler.start() } catch {
                log("после буста съём не поднялся (\(error.localizedDescription))")
            }
            var w = 0.0
            while sampler.luma == nil, w < 3 {
                try? await Task.sleep(nanoseconds: 50_000_000); w += 0.05
            }
            if let fresh = sampler.luma { smoothedLuma = fresh }
            lastTick = Date()
            log("буст снят, вернул \(pct(settledBrightness))")
            continue
        }

        // Жест на трекпаде: съём заглушен, вести яркость не по чему.
        if frozenByGesture {
            current = actual
            // Пока идёт ручная серия — не синхронизируемся: окно переключают
            // свайпом и тут же правят яркость клавишами, и эта ветка успевала
            // стереть правку раньше, чем её кто-либо видел.
            if !keysSeries { state.lastWritten = actual }
            halt("жест на трекпаде (ведение заморожено)")
            continue
        }

        // Выключено руками — не трогаем яркость вообще. Буст и перехват клавиш
        // при этом продолжают работать: выключатель про адаптацию, а не про всё.
        if !state.enabled {
            current = actual
            // Серию не копим: пока адаптация выключена, вести нечего, а дожив
            // до включения, она закрылась бы ручной правкой и тут же увела
            // демона в паузу — ровно против смысла включения.
            keysSeries = false
            state.lastWritten = actual
            velocity = 0
            moveFrom = nil
            continue
        }

        // ── Пауза на время игры ──────────────────────────────────────────────
        // Опрашиваем не каждый такт: для входа в игру и выхода из неё хватает
        // с запасом, а лишние обращения к NSWorkspace ни к чему.
        pauseCheckTick += 1
        if pauseCheckTick >= 5 {
            pauseCheckTick = 0
            var reason = ""
            if config.pauseOnGameMode && gameMode.active {
                reason = "Game Mode"
            } else if let front = frontmostBundleID(),
                      let hit = config.pauseApps.first(where: { !$0.isEmpty && front.hasPrefix($0) }) {
                reason = "впереди \(front) (совпало с «\(hit)»)"
            }

            if !reason.isEmpty, !paused {
                paused = true
                pauseReason = reason
                pauseBrightness = actual
                halt("пауза: \(reason)")
                await sampler.stop()
                log("пауза: \(reason). Яркость оставляю на \(pct(actual)), съём остановлен")
            } else if reason.isEmpty, paused {
                paused = false
                do {
                    try await sampler.start()
                } catch {
                    log("выход из паузы: съём не поднялся (\(error.localizedDescription))")
                }
                // Свежий кадр: за время игры прежняя светлота протухла, и
                // сглаживать от неё означало бы ехать от выдуманной точки.
                var waitedResume = 0.0
                while sampler.luma == nil, waitedResume < 3 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    waitedResume += 0.05
                }
                if let fresh = sampler.luma { smoothedLuma = fresh }

                current = actual
                state.lastWritten = actual
                holding = false
                state.holdLuma = nil

                // Если яркость за время игры крутили руками — это новая точка
                // отсчёта. Если нет, прежний baseline остаётся в силе: иначе
                // каждая игра незаметно сбивала бы калибровку.
                if abs(actual - pauseBrightness) > config.manualEpsilon {
                    state.baseline = actual
                    state.baselineLuma = smoothedLuma
                    log("выход из паузы (\(pauseReason)): яркость меняли вручную → новый baseline \(pct(actual))")
                } else {
                    log("выход из паузы (\(pauseReason)): веду от прежнего baseline \(pct(state.baseline))")
                }
                state.save()
                liveState.set(state)
                lastTick = Date()
                pauseReason = ""
                continue
            }
        }
        if paused { continue }

        // Съём мог встать: смена конфигурации дисплея, пробуждение, ошибка.
        // Перезапуск пробуем не чаще раза в 5с и пишем в лог по смене
        // состояния, а не каждый такт: если съём не поднимается, иначе выходило
        // бы по тридцать одинаковых строк в секунду.
        let failure = sampler.takeFailure()
        if failure != nil || sampler.silence > 5 {
            if !captureDown {
                captureDown = true
                log("съём встал (\(failure ?? "кадров нет больше 5с")) — перезапускаю")
            }
            if Date().timeIntervalSince(lastRestart) > 5 {
                lastRestart = Date()
                try? await sampler.start()
            }
            halt("съём встал")
            continue
        }
        if captureDown {
            captureDown = false
            log("съём восстановлен")
        }

        // Ждём устоявшуюся светлоту после перехода. Цикл при этом живой:
        // реагирует на жесты, клавиши и буст — просто не ведёт яркость.
        if steadyWait {
            let seen = sampler.frames
            if seen != steadySeen, let value = sampler.luma {
                steadySeen = seen
                if let prev = steadyPrev, abs(value - prev) <= config.lumaSettleEps {
                    smoothedLuma = value
                    steadyWait = false
                } else {
                    steadyPrev = value
                }
            }
            if steadyWait, Date() >= steadyUntil {
                // Анимация затянулась или контент живой и не устаивается вовсе
                // (видео). Берём что есть — это всё равно лучше протухшего.
                if let value = sampler.luma { smoothedLuma = value }
                steadyWait = false
            }
            if steadyWait {
                halt("жду устоявшуюся светлоту")
                continue
            }
            // Переход закончился. Номер стола SkyLight отдаёт позже картинки,
            // поэтому дальше ему какое-то время не верим: иначе он заглушит
            // съём второй раз и разорвёт уже идущий ход пополам.
            lastSpace = spaceWatch.current()
            spaceGraceUntil = Date().addingTimeInterval(max(0, config.spaceGrace))
            lastTick = Date()
            if config.traceEvents || config.traceKeys {
                log(String(format: "  [переход] светлота устоялась на %.3f, стол=%d, отсрочка %.1fс",
                           smoothedLuma, Int(lastSpace), config.spaceGrace))
            }
        }

        if let raw = sampler.luma {
            // Сразу после рампа системы сглаживать не от чего: прежняя светлота
            // относится к докам сна. Берём свежий кадр как есть.
            if wakeSettleUntil != .distantPast, Date().timeIntervalSince(wakeSettleUntil) < 1 {
                smoothedLuma = raw
                wakeSettleUntil = .distantPast
                lastTick = Date()
            } else {
                smoothedLuma += (raw - smoothedLuma) * (1 - exp(-dt / max(0.01, config.tauLuma)))
            }
        }

        // ── Светлота после правки ещё едет ───────────────────────────────────
        // Сглаживание имеет инерцию `tauLuma`, и правка сразу после
        // переключения окна попадает на полпути: baseline привязался бы к
        // светлоте, которой на экране не было. Через секунду сглаженная
        // доходит до настоящей, расхождение с ней перешагивает порог — и
        // демон объявляет «контент сменился», хотя окно всё то же, и едет
        // обратно. Поэтому пока сглаженная догоняет сырую, точку отсчёта
        // дописываем свежей светлотой.
        if lumaSettling {
            if !holding || Date() >= lumaSettlingUntil {
                lumaSettling = false
            } else if let raw = sampler.luma, abs(raw - smoothedLuma) > config.lumaSettleEps {
                state.baselineLuma = smoothedLuma
                holdLuma = smoothedLuma
                state.holdLuma = smoothedLuma
            } else {
                lumaSettling = false
                state.save()
                liveState.set(state)
            }
        }

        // ── Рука на клавишах яркости ─────────────────────────────────────────
        // Серия закрывается не по таймеру, а по факту: клавиши затихли И
        // подсветка перестала меняться. Таймер сам по себе ничего не
        // гарантировал — стоило системному рампу не уложиться в него, и
        // пружина записывала своё значение поверх, стирая след правки вместе
        // с самой правкой. Теперь до закрытия серии демон не пишет вообще.
        if keysSeries {
            halt("клавиши яркости")

            let quiet = keysClock.secondsSince() >= config.keySettle
            let still = Date().timeIntervalSince(keysSeriesStill) >= config.keyStill
            let overdue = Date().timeIntervalSince(keysSeriesStart) >= config.keySeriesMax
            guard (quiet && still) || overdue else { continue }

            keysSeries = false
            if !dryRun, abs(actual - keysSeriesWritten) > config.manualEpsilon {
                acceptManual(actual)
                continue
            }
            // Ничего не изменилось: упёрлись в край шкалы или нажатие ушло
            // мимо. Выдумывать ручную правку не за чем — ведём дальше.
            current = actual
        }

        // ── Внешняя правка ───────────────────────────────────────────────────
        // Чтение возвращает записанное бит-в-бит, поэтому любое расхождение —
        // это не мы: клавиши, Control Center или системный датчик освещённости.
        // Ловим всегда, в том числе посреди хода: гасим скорость и замираем
        // ровно там, где нас остановили, а выставленное значение принимаем за
        // новый baseline при текущей светлоте.
        if !dryRun, abs(actual - state.lastWritten) > config.manualEpsilon {
            acceptManual(actual)
            continue
        }
        if dryRun {
            state.lastWritten = actual
            if moveFrom == nil { current = actual }
        }

        // ── Пауза до смены контента ──────────────────────────────────────────
        // Сравниваем с исходной точкой, а не с прошлым тактом: медленный дрейф
        // контента накапливается и в конце концов порог всё равно перешагнёт.
        if holding {
            let drift = abs(normalizedLuma(smoothedLuma, config) - normalizedLuma(holdLuma, config))
            guard drift > config.resumeLumaDelta else {
                current = actual
                continue
            }
            holding = false
            state.holdLuma = nil
            if !dryRun { state.save() }
            liveState.set(state)
            manualPending = false
            log(String(format: "контент сменился (norm %.2f → %.2f) → снова веду",
                       normalizedLuma(holdLuma, config), normalizedLuma(smoothedLuma, config)))
        }

        // ── Ведение ──────────────────────────────────────────────────────────
        let target = targetBrightness(luma: smoothedLuma, state: state, config: config)

        // Из покоя трогаемся только на заметном расхождении, иначе рябь контента
        // вызывала бы мелкую дрожь. Уже идущий ход этот порог не тормозит.
        if moveFrom == nil {
            guard abs(target - current) > config.startThreshold else { continue }
            moveFrom = current
            moveStarted = Date()
            moveWrites = 0
        }

        // Критически демпфированная пружина в устойчивой дискретной форме.
        // Перелёта не даёт по построению, а цель можно менять на каждом такте —
        // поэтому смена контента посреди хода подхватывается без разрыва.
        let x = omega * dt
        let decay = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
        let offset = current - target
        let temp = (velocity + omega * offset) * dt
        velocity = (velocity - omega * temp) * decay
        current = target + (offset + temp) * decay

        // Упор в потолок или пол гасит скорость, иначе пружина «заводится»
        // на рельсе и потом выстреливает обратно.
        let clamped = max(config.minBrightness, min(config.maxBrightness, current))
        if clamped != current {
            current = clamped
            velocity = 0
        }

        let settled = abs(target - current) < config.stopThreshold
                   && abs(velocity) * dt < config.stopThreshold
        if settled {
            current = target
            velocity = 0
        }

        // Писать одно и то же значение по тридцать раз в секунду не за чем,
        // и лишние записи размывали бы детект внешней правки.
        if abs(current - state.lastWritten) > 1e-5 {
            if !dryRun { backlight.write(display, current) }
            state.lastWritten = current
            liveState.set(state)
            if moveFrom != nil { moveWrites += 1 }
        }

        if settled, let from = moveFrom {
            if !dryRun { state.save() }
            liveState.set(state)
            let elapsed = Date().timeIntervalSince(moveStarted)
            let stepPct = moveWrites > 0 ? abs(target - from) / Double(moveWrites) * 100 : 0
            log(String(format: "luma=%.3f (norm %.2f)  вёл %@ → %@, %.1fс%@%@",
                       smoothedLuma, normalizedLuma(smoothedLuma, config),
                       pct(from), pct(target), elapsed,
                       (config.traceEvents || config.traceKeys)
                           ? String(format: "  [%d записей, %.1f/с, шаг %.2f%%]",
                                    moveWrites, elapsed > 0 ? Double(moveWrites) / elapsed : 0, stepPct)
                           : "",
                       dryRun ? "  [не применено]" : ""))
            moveFrom = nil
            if singleShot { return }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Вспомогательные команды
// ─────────────────────────────────────────────────────────────────────────────

func runProbe() async {
    let config = Config.load()
    let display = CGMainDisplayID()
    guard let backlight = Backlight() else { log("нет доступа к DisplayServices"); exit(1) }
    let sampler = ScreenSampler(width: config.sampleWidth, height: config.sampleHeight)

    print("Переключайся между приложениями. Ctrl-C чтобы выйти.")
    print("luma — сырая светлота экрана, norm — она же после darkPoint/lightPoint.\n")
    while true {
        do {
            let l = try await sampler.luma()
            let b = backlight.read(display) ?? -1
            print(String(format: "luma=%.3f   norm=%.2f   яркость=%@",
                         l, normalizedLuma(l, config), pct(b)))
        } catch {
            print("захват не удался: \(error.localizedDescription)")
            sampler.invalidate()
        }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

func runStatus() async {
    let config = Config.load()
    let display = CGMainDisplayID()
    guard let backlight = Backlight() else { print("нет доступа к DisplayServices"); exit(1) }
    let actual = backlight.read(display) ?? -1

    print("Яркость сейчас:   \(pct(actual))")
    if let s = State.load() {
        print("Baseline:         \(pct(s.baseline)) при светлоте \(String(format: "%.3f", s.baselineLuma)) (norm \(String(format: "%.2f", normalizedLuma(s.baselineLuma, config))))")
        print("Демон выставлял:  \(pct(s.lastWritten))")
        let on = EnableChannel.read() ?? s.enabled
        if !on {
            print("Адаптация:        ВЫКЛЮЧЕНА (аккорд «ярче+тусклее» или `toggle`)")
        }
        if let h = s.holdLuma {
            print("Пауза:            держу после ручной правки, жду смены контента")
            print("                  снимется, когда norm уедет от \(String(format: "%.2f", normalizedLuma(h, config))) больше чем на \(config.resumeLumaDelta)")
        }
        do {
            let l = try await ScreenSampler(width: config.sampleWidth, height: config.sampleHeight).luma()
            print("Светлота сейчас:  \(String(format: "%.3f", l)) (norm \(String(format: "%.2f", normalizedLuma(l, config))))")
            print("Цель:             \(pct(targetBrightness(luma: l, state: s, config: config)))")
        } catch {
            print("Светлота сейчас:  недоступна (\(error.localizedDescription))")
        }
    } else {
        print("Baseline:         не задан (демон ещё не запускался)")
    }
    print("")
    print("Конфиг:           \(FileManager.default.fileExists(atPath: configURL.path) ? configURL.path : "\(configURL.path) (нет, используются дефолты)")")
    print("span=\(config.span)  dark=\(config.darkPoint)  light=\(config.lightPoint)")
    print("tauLuma=\(config.tauLuma)s  travelTime=\(config.travelTime)s  resumeLumaDelta=\(config.resumeLumaDelta)")
    print("control=\(Int(config.controlHz))Гц  capture=\(Int(config.captureHz))Гц")
    print("range=[\(pct(config.minBrightness)), \(pct(config.maxBrightness))]")
    if config.maxBoost > 1.0 {
        let level = BoostChannel.read() ?? 1.0
        print("Буст XDR:         \(level > 1.0001 ? String(format: "%.0f%%", level * 100) : "выключен")  (потолок \(Int(config.maxBoost * 100))%)")
        let tapLine: String
        if !config.nativeKeysBoost {
            tapLine = "отключён в конфиге"
        } else {
            switch TapStatusChannel.read() {
            case .some(true):  tapLine = "работает"
            case .some(false): tapLine = "не поднялся — нужно разрешение Accessibility"
            case nil:          tapLine = "демон ещё не сообщал (запущен ли он?)"
            }
        }
        print("Перехват клавиш:  \(tapLine)")
    }
}

func runReset() async {
    ensureDirs()
    let config = Config.load()
    let display = CGMainDisplayID()
    guard let backlight = Backlight(), let actual = backlight.read(display) else {
        print("нет доступа к подсветке"); exit(1)
    }
    do {
        let l = try await ScreenSampler(width: config.sampleWidth, height: config.sampleHeight).luma()
        State(baseline: actual, baselineLuma: l, lastWritten: actual, enabled: true, holdLuma: nil).save()
        print("Baseline сброшен: \(pct(actual)) при светлоте \(String(format: "%.3f", l))")
    } catch {
        print("не удалось снять кадр: \(error.localizedDescription)"); exit(2)
    }
}

func usage() {
    print("""
    adaptive-brightness — адаптивная яркость по содержимому экрана

      run            цикл демона (это запускает launchd)
      once           один такт с применением, затем выход
      dry-run        цикл без изменения яркости, только лог того, что сделал бы
      probe          печатать светлоту экрана раз в секунду (подбор darkPoint/lightPoint)
      status         текущее состояние, baseline и цель
      reset          принять текущую яркость как новый baseline
      toggle         включить/выключить адаптацию (то же, что аккорд «ярче+тусклее»)
      boost <N>      яркость выше 100% на XDR: 1.35 или 135. boost 1 — выключить

    Конфиг: ~/.config/adaptive-brightness/config.json
    Лог:    ~/.local/state/adaptive-brightness/daemon.log
    """)
}

// ─────────────────────────────────────────────────────────────────────────────

let args = CommandLine.arguments.dropFirst()
switch args.first ?? "run" {
case "run":
    logToFile = true
    // Metal-окну для EDR нужен полноценный runloop AppKit, поэтому демон
    // теперь приложение-агент. LSUIElement в Info.plist держит его вне дока.
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Task { @MainActor in
        await runDaemon(dryRun: false, singleShot: false)
    }
    app.run()
case "once":
    await runDaemon(dryRun: false, singleShot: true)
case "dry-run":
    await runDaemon(dryRun: true, singleShot: false)
case "probe":
    await runProbe()
case "toggle":
    // Тот же выключатель, что и аккорд, — на случай если клавиш под рукой нет.
    let now = EnableChannel.read() ?? State.load()?.enabled ?? true
    if EnableChannel.write(!now) {
        print(!now ? "адаптация включена" : "адаптация выключена")
        print("(применяет демон; если он не запущен, ничего не произойдёт)")
    } else {
        print("не удалось переключить")
        exit(1)
    }
case "boost":
    let v = args.dropFirst().first.flatMap { Double($0) } ?? 1.0
    // Значения принимаем и как 1.35, и как 135 — так удобнее с клавиатуры.
    let level = v > 10 ? v / 100 : v
    if BoostChannel.write(level) {
        print(level <= 1.0001
              ? "буст выключен"
              : String(format: "буст запрошен: %.0f%%", level * 100))
        print("(применяет демон; если он не запущен, ничего не произойдёт)")
    } else {
        print("не удалось записать уровень буста")
        exit(1)
    }
case "status":
    await runStatus()
case "reset":
    await runReset()
default:
    usage()
}
