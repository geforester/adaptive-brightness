import Foundation

// ─────────────────────────────────────────────────────────────────────────────
// Чистая модель: никаких системных вызовов, время приходит снаружи.
//
// Отдельный файл ради тестов: tests/main.swift собирается с ним одним, без
// AppKit, ScreenCaptureKit и прочего, до чего тестам дела нет.
// ─────────────────────────────────────────────────────────────────────────────

/// Светлота кадра → [0, 1] между «полностью тёмным» и «полностью светлым».
func normalizedLuma(_ luma: Double, darkPoint: Double, lightPoint: Double) -> Double {
    let span = max(1e-6, lightPoint - darkPoint)
    return max(0, min(1, (luma - darkPoint) / span))
}

/// Геометрическая интерполяция между концами: глаз воспринимает яркость
/// кратно, и равные шаги в середине шкалы иначе читались бы как рывок.
func interpolatedBrightness(n: Double, dark: Double, light: Double, min lo: Double, max hi: Double) -> Double {
    let d = max(1e-4, dark)
    let l = max(1e-4, light)
    return max(lo, min(hi, d * pow(l / d, n)))
}

/// В чью зону попала ручная правка и куда после неё встали концы.
struct Calibration {
    enum Zone { case dark, light, middle }
    var zone: Zone
    var dark: Double
    var light: Double
    /// Правка перескочила соседний конец, и он подтянут следом — кривая плоская.
    var crossed: Bool
}

/// Положить выставленное значение в ту точку, в чьей зоне мы находимся.
///
/// Конец пересчитывается так, чтобы кривая прошла ровно через выставленное
/// значение при текущей светлоте: выставил 60% — 60% и останется. На краю
/// шкалы это почти тождество, к середине пересчёт усиливается — потому
/// середина в точки и не пишется.
func calibratePoints(value: Double, n: Double, dark: Double, light: Double,
               edge: Double, min lo: Double, max hi: Double) -> Calibration {
    let e = max(0, min(0.5, edge))
    let clampPoint = { (x: Double) in max(lo, min(hi, x)) }
    if n <= e {
        // value = dark^(1−n) · light^n  ⇒  dark = (value / light^n)^(1/(1−n))
        let newDark = clampPoint(pow(value / pow(max(1e-4, light), n), 1 / max(1e-6, 1 - n)))
        // Пересечение не подрезаем: выставленное рукой важнее сохранённого
        // соседа — иначе демон отыграл бы нажатие назад. Сосед идёт следом.
        let crossed = newDark < light
        return Calibration(zone: .dark, dark: newDark, light: crossed ? newDark : light, crossed: crossed)
    }
    if n >= 1 - e {
        let newLight = clampPoint(pow(value / pow(max(1e-4, dark), 1 - n), 1 / max(1e-6, n)))
        let crossed = newLight > dark
        return Calibration(zone: .light, dark: crossed ? newLight : dark, light: newLight, crossed: crossed)
    }
    return Calibration(zone: .middle, dark: dark, light: light, crossed: false)
}

/// Критически демпфированная пружина в устойчивой дискретной форме. Перелёта
/// не даёт по построению, а цель можно менять на каждом такте.
func springStep(current: Double, velocity: Double, target: Double,
                omega: Double, dt: Double) -> (current: Double, velocity: Double) {
    let x = omega * dt
    let decay = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
    let offset = current - target
    let temp = (velocity + omega * offset) * dt
    return (target + (offset + temp) * decay, (velocity - omega * temp) * decay)
}

func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

// ─────────────────────────────────────────────────────────────────────────────
// Внешний монитор
// ─────────────────────────────────────────────────────────────────────────────

struct ExternalParams {
    var darkPoint = 0.15
    var lightPoint = 0.80
    var minBrightness = 0.15
    var maxBrightness = 1.0
    var travelTime = 1.1
    var tauLuma = 0.6
    var resumeLumaDelta = 0.12
    var calibrateEdge = 0.2
    var startThreshold = 0.02
    var stopThreshold = 0.002
    /// Тишина на клавишах, после которой серия нажатий считается законченной.
    var keySettle = 0.6
    /// Шаг одного нажатия — тот же 1/16, что у системных клавиш.
    var keyStep = 1.0 / 16.0
    var lumaSettleEps = 0.02
    var lumaSettleMax = 1.5
}

/// Адаптация одного внешнего монитора.
///
/// Отличие от встроенной панели одно, но определяющее: яркость монитора по DDC
/// не читается (Dell P2415Q отвечает нулями). Поэтому «что стоит на мониторе»
/// здесь — это то, что мы сами записали, и ручная правка видна не по
/// расхождению прочитанного с записанным, а напрямую: клавиши под курсором на
/// этом мониторе перехватываем мы и сами двигаем `written`. Кнопки на корпусе
/// монитора не видны никак.
struct ExternalModel {
    let p: ExternalParams
    var dark: Double
    var light: Double
    /// Что сейчас скомандовано монитору.
    private(set) var written: Double
    private(set) var holdLuma: Double?
    private(set) var smoothedLuma: Double?

    private var current: Double
    private var velocity = 0.0
    private var moveFrom: Double?
    private var moveStarted = 0.0

    private(set) var keySeries = false
    private var keySeriesFrom = 0.0
    private var keyLastAt = 0.0

    private var pendingManual: Double?
    private var settlingUntil = 0.0
    private var wasFrozen = false

    init(params: ExternalParams, dark: Double, light: Double, written: Double, holdLuma: Double?) {
        p = params
        self.dark = dark
        self.light = light
        self.written = written
        self.holdLuma = holdLuma
        current = written
    }

    func normalized(_ luma: Double) -> Double {
        normalizedLuma(luma, darkPoint: p.darkPoint, lightPoint: p.lightPoint)
    }

    func target(_ luma: Double) -> Double {
        interpolatedBrightness(n: normalized(luma), dark: dark, light: light,
                               min: p.minBrightness, max: p.maxBrightness)
    }

    private mutating func halt() {
        velocity = 0
        moveFrom = nil
    }

    /// Нажатия клавиш яркости под курсором на этом мониторе. Возвращает новое
    /// значение — его надо записать сразу, не дожидаясь такта.
    mutating func keys(_ steps: Int, now: Double) -> Double {
        if !keySeries {
            keySeries = true
            keySeriesFrom = written
        }
        keyLastAt = now
        halt()
        written = max(0, min(1, written + Double(steps) * p.keyStep))
        current = written
        return written
    }

    /// Серию прервал аккорд «ярче + тусклее»: это команда, а не правка.
    /// Возвращает значение, к которому откатиться.
    mutating func cancelKeys() -> Double? {
        guard keySeries else { return nil }
        keySeries = false
        written = keySeriesFrom
        current = written
        return written
    }

    enum Event: Equatable {
        /// Серия клавиш закончилась на этом значении.
        case manual(Double)
        /// Правку положили в точку (или в середину, тогда точки прежние).
        case calibrated(Calibration.Zone, dark: Double, light: Double, crossed: Bool)
        case resumed(from: Double, to: Double)
        case moved(from: Double, to: Double, seconds: Double)
    }

    struct Output {
        var write: Double?
        var events: [Event] = []
    }

    /// Один такт.
    ///
    /// - `luma`: свежая светлота этого монитора или nil, если кадра нет.
    /// - `frozen`: вести нельзя — жест, смена стола, пауза, выключенная
    ///   адаптация. Клавиши при этом работают: их обрабатывает `keys`.
    mutating func tick(now: Double, dt: Double, luma: Double?, frozen: Bool) -> Output {
        var out = Output()

        if keySeries {
            guard now - keyLastAt >= p.keySettle else { return out }
            keySeries = false
            if abs(written - keySeriesFrom) > 1e-6 {
                acceptManual(now: now)
                out.events.append(.manual(written))
            }
        }

        if frozen {
            halt()
            wasFrozen = true
            return out
        }
        if wasFrozen {
            // За время заморозки контент мог смениться — сглаживать от
            // протухшей светлоты означало бы ехать от выдуманной точки.
            wasFrozen = false
            smoothedLuma = nil
        }

        if let raw = luma {
            if let s = smoothedLuma {
                smoothedLuma = s + (raw - s) * (1 - exp(-dt / max(0.01, p.tauLuma)))
            } else {
                smoothedLuma = raw
            }
        }
        guard let smoothed = smoothedLuma else { return out }

        // Правку относим к зоне, только когда светлота устоялась: сразу после
        // переключения окна сглаженная ещё едет к настоящей.
        if let value = pendingManual {
            let settled = luma.map { abs($0 - smoothed) <= p.lumaSettleEps } ?? false
            guard settled || now >= settlingUntil else { return out }
            pendingManual = nil
            holdLuma = smoothed
            let c = calibratePoints(value: value, n: normalized(smoothed), dark: dark, light: light,
                              edge: p.calibrateEdge, min: p.minBrightness, max: p.maxBrightness)
            dark = c.dark
            light = c.light
            if c.zone != .middle { holdLuma = nil }
            out.events.append(.calibrated(c.zone, dark: c.dark, light: c.light, crossed: c.crossed))
        }

        if let h = holdLuma {
            let from = normalized(h), to = normalized(smoothed)
            guard abs(to - from) > p.resumeLumaDelta else { return out }
            holdLuma = nil
            out.events.append(.resumed(from: from, to: to))
        }

        let goal = target(smoothed)
        if moveFrom == nil {
            guard abs(goal - current) > p.startThreshold else { return out }
            moveFrom = current
            moveStarted = now
        }

        let step = springStep(current: current, velocity: velocity, target: goal,
                              omega: 6.0 / max(0.05, p.travelTime), dt: dt)
        current = step.current
        velocity = step.velocity
        let clamped = max(p.minBrightness, min(p.maxBrightness, current))
        if clamped != current {
            current = clamped
            velocity = 0
        }
        let settled = abs(goal - current) < p.stopThreshold && abs(velocity) * dt < p.stopThreshold
        if settled {
            current = goal
            velocity = 0
        }
        if abs(current - written) > 1e-5 {
            written = current
            out.write = current
        }
        if settled, let from = moveFrom {
            out.events.append(.moved(from: from, to: goal, seconds: now - moveStarted))
            moveFrom = nil
        }
        return out
    }

    private mutating func acceptManual(now: Double) {
        halt()
        current = written
        holdLuma = smoothedLuma
        pendingManual = written
        settlingUntil = now + max(0, p.lumaSettleMax)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ход DDC-записей
// ─────────────────────────────────────────────────────────────────────────────

/// Куда сделать следующий шаг по шкале DDC. Скачок в несколько единиц монитор
/// показывает рывком, поэтому идём по одной единице за раз; темп задаёт
/// писатель. Первая запись (`sent == nil`) — сразу в цель: что стоит на
/// мониторе, мы не знаем, и ехать не от чего.
func nextDDCValue(sent: Int?, target: Int) -> Int? {
    guard let s = sent else { return target }
    if s == target { return nil }
    return s + (target > s ? 1 : -1)
}

/// Доля [0, 1] → значение DDC [0, max].
func ddcValue(_ v: Double, max m: Int) -> Int {
    Int((max(0, min(1, v)) * Double(m)).rounded())
}
