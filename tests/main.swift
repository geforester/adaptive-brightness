import Foundation

// Тесты чистой модели (src/model.swift). Запуск: ./test.sh
//
// Харнесс самодельный: проект собирается голым swiftc без SwiftPM, и тянуть
// XCTest ради десятка проверок незачем.

var failures = 0
var checks = 0

func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !ok {
        failures += 1
        print("  ✗ \(what)  (\((file as NSString).lastPathComponent):\(line))")
    }
}

func near(_ a: Double, _ b: Double, _ eps: Double = 1e-3) -> Bool { abs(a - b) <= eps }

func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

// Светлоты, которые нормируются ровно в края и середину при дефолтных
// darkPoint=0.15, lightPoint=0.80.
let darkLuma = 0.10
let lightLuma = 0.90
let midLuma = 0.475

/// Прогон модели с шагом 1/60 с. Время — общий счётчик на весь тест.
struct Sim {
    var m: ExternalModel
    var now = 1000.0
    var writes: [Double] = []
    var events: [ExternalModel.Event] = []

    init(_ m: ExternalModel) { self.m = m }

    mutating func run(_ seconds: Double, luma: Double?, frozen: Bool = false) {
        let dt = 1.0 / 60
        for _ in 0..<Int((seconds / dt).rounded()) {
            now += dt
            let out = m.tick(now: now, dt: dt, luma: luma, frozen: frozen)
            if let w = out.write { writes.append(w) }
            events += out.events
        }
    }

    mutating func keys(_ n: Int) -> Double { m.keys(n, now: now) }

    mutating func clear() { writes = []; events = [] }

    var manuals: [Double] { events.compactMap { if case .manual(let v) = $0 { return v }; return nil } }
    var calibrations: [(Calibration.Zone, Double, Double)] {
        events.compactMap { if case .calibrated(let z, let d, let l, _) = $0 { return (z, d, l) }; return nil }
    }
    var resumed: Bool { events.contains { if case .resumed = $0 { return true }; return false } }
}

func model(dark: Double = 0.7, light: Double = 0.4, written: Double = 0.7, hold: Double? = nil) -> ExternalModel {
    ExternalModel(params: ExternalParams(), dark: dark, light: light, written: written, holdLuma: hold)
}

// ─────────────────────────────────────────────────────────────────────────────

test("калибровка: тёмная и светлая зоны ложатся в свою точку") {
    let d = calibratePoints(value: 0.8, n: 0, dark: 0.7, light: 0.4, edge: 0.25, min: 0.15, max: 1)
    check(d.zone == .dark && near(d.dark, 0.8) && near(d.light, 0.4) && !d.crossed, "тёмная: \(d)")
    let l = calibratePoints(value: 0.3, n: 1, dark: 0.7, light: 0.4, edge: 0.25, min: 0.15, max: 1)
    check(l.zone == .light && near(l.light, 0.3) && near(l.dark, 0.7) && !l.crossed, "светлая: \(l)")
}

test("калибровка: кривая проходит ровно через выставленное значение на краю зоны") {
    let n = 0.2
    let c = calibratePoints(value: 0.65, n: n, dark: 0.7, light: 0.4, edge: 0.25, min: 0.15, max: 1)
    check(c.zone == .dark, "зона тёмная")
    check(near(interpolatedBrightness(n: n, dark: c.dark, light: c.light, min: 0.15, max: 1), 0.65),
          "на этой светлоте цель = 65%")
}

test("калибровка: середина точек не трогает") {
    let c = calibratePoints(value: 0.9, n: 0.5, dark: 0.7, light: 0.4, edge: 0.25, min: 0.15, max: 1)
    check(c.zone == .middle && c.dark == 0.7 && c.light == 0.4, "\(c)")
}

test("калибровка: перескочивший конец тащит соседа, пара не переворачивается") {
    let d = calibratePoints(value: 0.3, n: 0, dark: 0.7, light: 0.4, edge: 0.25, min: 0.15, max: 1)
    check(d.crossed && near(d.dark, 0.3) && near(d.light, 0.3), "тёмный ниже светлого: \(d)")
    let l = calibratePoints(value: 0.9, n: 1, dark: 0.7, light: 0.4, edge: 0.25, min: 0.15, max: 1)
    check(l.crossed && near(l.light, 0.9) && near(l.dark, 0.9), "светлый выше тёмного: \(l)")
}

test("калибровка: точки не выходят за границы") {
    let c = calibratePoints(value: 0.05, n: 0, dark: 0.7, light: 0.4, edge: 0.25, min: 0.15, max: 1)
    check(near(c.dark, 0.15), "нижняя граница: \(c)")
}

test("DDC: первая запись — сразу в цель, дальше по одной единице") {
    check(nextDDCValue(sent: nil, target: 40) == 40, "без известного значения — в цель")
    check(nextDDCValue(sent: 70, target: 40) == 69, "вниз на 1")
    check(nextDDCValue(sent: 40, target: 70) == 41, "вверх на 1")
    check(nextDDCValue(sent: 55, target: 55) == nil, "на месте — писать нечего")
    var v: Int? = 70, n = 0
    while let next = nextDDCValue(sent: v, target: 40) { v = next; n += 1 }
    check(v == 40 && n == 30, "70→40 за 30 записей, вышло \(n)")
}

test("DDC: доля → шкала монитора с округлением и зажимом") {
    check(ddcValue(0.5, max: 100) == 50, "50%")
    check(ddcValue(0.825, max: 100) == 83, "округление")
    check(ddcValue(1.3, max: 100) == 100 && ddcValue(-0.1, max: 100) == 0, "зажим")
}

test("адаптация: тёмный экран → тёмная точка, светлый → светлая, без перелёта") {
    var s = Sim(model(written: 0.55))
    s.run(3, luma: darkLuma)
    check(near(s.m.written, 0.7), "на тёмном пришли к 70%, стоим на \(s.m.written)")
    check(zip(s.writes, s.writes.dropFirst()).allSatisfy { $0 <= $1 + 1e-9 }, "ход монотонный")
    check(s.writes.allSatisfy { $0 <= 0.7 + 1e-9 }, "перелёта нет")
    s.clear()
    s.run(4, luma: lightLuma)
    check(near(s.m.written, 0.4), "на светлом пришли к 40%, стоим на \(s.m.written)")
    check(s.events.contains { if case .moved = $0 { return true }; return false }, "ход записан событием")
}

test("адаптация: мелкая рябь контента не трогает яркость") {
    var s = Sim(model())
    s.run(2, luma: darkLuma)
    s.clear()
    s.run(2, luma: darkLuma + 0.005)
    check(s.writes.isEmpty, "записей не было: \(s.writes.count)")
}

test("клавиши: нажатие пишется сразу, правка ложится в тёмную точку") {
    var s = Sim(model())
    s.run(2, luma: darkLuma)
    let v = s.keys(+2)
    check(near(v, 0.825), "70% + 2×1/16 = 82.5%, вышло \(v)")
    s.clear()
    s.run(0.2, luma: darkLuma)
    check(s.writes.isEmpty && s.manuals.isEmpty, "пока серия идёт — ни записей, ни правки")
    s.run(2, luma: darkLuma)
    check(s.manuals == [0.825], "правка принята: \(s.manuals)")
    check(s.calibrations.count == 1 && s.calibrations[0].0 == .dark && near(s.calibrations[0].1, 0.825),
          "тёмная точка = 82.5%: \(s.calibrations)")
    check(s.writes.isEmpty, "после правки демон не отъезжает: \(s.writes)")
    check(s.m.holdLuma == nil, "в зоне точки паузы нет — дальше ведём от новой точки")
}

test("клавиши: серия из нескольких нажатий — одна правка, по итогу") {
    var s = Sim(model())
    s.run(2, luma: darkLuma)
    _ = s.keys(+1); s.run(0.15, luma: darkLuma)
    _ = s.keys(+1); s.run(0.15, luma: darkLuma)
    _ = s.keys(-1); s.run(2, luma: darkLuma)
    check(s.manuals.count == 1 && near(s.manuals[0], 0.7625), "одна правка на 76%: \(s.manuals)")
}

test("клавиши: туда-обратно в ноль — не правка, ведение продолжается") {
    var s = Sim(model())
    s.run(2, luma: darkLuma)
    _ = s.keys(+1); _ = s.keys(-1)
    s.clear()
    s.run(2, luma: darkLuma)
    check(s.manuals.isEmpty && s.calibrations.isEmpty, "правки нет: \(s.events)")
    s.run(4, luma: lightLuma)
    check(near(s.m.written, 0.4), "на светлом ведёт как обычно")
}

test("клавиши: правка на середине держится до смены контента") {
    var s = Sim(model())
    s.run(4, luma: midLuma)
    let before = s.m.written
    _ = s.keys(+3)
    s.clear()
    s.run(3, luma: midLuma)
    check(s.calibrations.count == 1 && s.calibrations[0].0 == .middle, "середина: \(s.calibrations)")
    check(near(s.m.dark, 0.7) && near(s.m.light, 0.4), "точки прежние")
    check(near(s.m.written, before + 3.0 / 16), "держит выставленное")
    s.run(3, luma: midLuma + 0.03)
    check(s.writes.isEmpty, "небольшой дрейф контента не снимает паузу")
    s.run(4, luma: lightLuma)
    check(s.resumed, "заметная смена контента снимает паузу")
    check(near(s.m.written, 0.4), "и дальше ведёт к светлой точке")
}

test("клавиши: посреди хода гасят его и берут текущее значение") {
    var s = Sim(model(written: 0.4))
    s.run(0.3, luma: darkLuma)
    let mid = s.m.written
    check(mid > 0.4 && mid < 0.7, "ход идёт: \(mid)")
    let v = s.keys(-1)
    check(near(v, mid - 1.0 / 16), "шаг от текущего положения, а не от цели")
    s.clear()
    s.run(0.2, luma: darkLuma)
    check(s.writes.isEmpty, "ход остановлен")
}

test("клавиши: упор в 0 и 100%") {
    var s = Sim(model(written: 0.95))
    check(near(s.keys(+5), 1.0), "потолок")
    check(near(s.keys(-40), 0.0), "пол")
}

test("аккорд: серию отменяет, правки нет, значение откатывается") {
    var s = Sim(model())
    s.run(2, luma: darkLuma)
    _ = s.keys(+1)
    let back = s.m.cancelKeys()
    check(back.map { near($0, 0.7) } ?? false, "откат к 70%: \(String(describing: back))")
    s.clear()
    s.run(2, luma: darkLuma)
    check(s.manuals.isEmpty && s.calibrations.isEmpty, "правки нет")
    check(s.m.cancelKeys() == nil, "без серии отменять нечего")
}

test("заморозка: не ведёт, клавиши работают, после — свежая светлота без сглаживания") {
    var s = Sim(model())
    s.run(2, luma: darkLuma)
    s.clear()
    s.run(1, luma: lightLuma, frozen: true)
    check(s.writes.isEmpty, "замороженный не пишет")
    let v = s.keys(+1)
    check(near(v, 0.7625), "клавиши работают и в заморозке")
    s.run(1, luma: lightLuma, frozen: true)
    check(s.manuals.count == 1, "правка в заморозке принята")
    s.run(0.05, luma: lightLuma)
    check(s.m.smoothedLuma.map { near($0, lightLuma) } ?? false,
          "после заморозки светлота взята как есть: \(String(describing: s.m.smoothedLuma))")
}

test("без кадров: не ведёт и не выдумывает светлоту") {
    var s = Sim(model(written: 0.4))
    s.run(2, luma: nil)
    check(s.writes.isEmpty, "кадров нет — записей нет")
}

test("состояние: пауза из файла переживает перезапуск") {
    var s = Sim(model(written: 0.9, hold: midLuma))
    s.run(2, luma: midLuma)
    check(s.writes.isEmpty, "держит 90% до смены контента")
    s.run(4, luma: darkLuma)
    check(s.resumed && near(s.m.written, 0.7), "после смены контента ведёт")
}

print(failures == 0 ? "\nвсе \(checks) проверок прошли" : "\nпровалено \(failures) из \(checks)")
exit(failures == 0 ? 0 : 1)
