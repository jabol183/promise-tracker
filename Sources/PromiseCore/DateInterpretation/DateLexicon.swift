import Foundation

/// Language-specific vocabulary for deadline phrases. All entries are in
/// `TextNormalizer` form (lowercase, no diacritics) because matching runs on
/// normalized text. English ships first; Polish is included to prove the
/// architecture and is only enabled after runtime/locale checks in the app.
public struct DateLexicon: Sendable {
    public var languageCode: String
    public var today: [String]
    public var tonight: [String]
    public var tomorrow: [String]
    public var dayAfterTomorrow: [String]
    /// Index 0 = Sunday … 6 = Saturday (matching `Calendar` weekday - 1). Each entry
    /// lists every inflected or abbreviated form.
    public var weekdays: [[String]]
    /// Index 0 = January.
    public var months: [[String]]
    public var thisModifiers: [String]
    public var nextModifiers: [String]
    public var thisWeek: [String]
    public var nextWeek: [String]
    public var thisWeekend: [String]
    public var nextWeekend: [String]
    public var thisMonth: [String]
    public var nextMonth: [String]
    public var endOfMonth: [String]
    public var endOfDay: [String]
    public var morning: [String]
    public var afternoon: [String]
    public var evening: [String]
    public var noon: [String]
    public var midnight: [String]
    public var vague: [String]
    public var coupleOfDays: [String]
    public var fewDays: [String]
    public var eventLinked: [String]
    /// Leading words that introduce a deadline ("by", "on", "before").
    public var prepositions: [String]
    public var timePrepositions: [String]
    public var amMarkers: [String]
    public var pmMarkers: [String]
    /// Number words 1...12 (index 0 = one).
    public var numberWords: [[String]]
    /// "in" for relative offsets, followed by units.
    public var inWord: [String]
    public var dayUnits: [String]
    public var weekUnits: [String]
    public var monthUnits: [String]
    public var hourUnits: [String]
    public var minuteUnits: [String]
    public var articleOne: [String]

    public static let english = DateLexicon(
        languageCode: "en",
        today: ["today", "later today"],
        tonight: ["tonight", "this evening"],
        tomorrow: ["tomorrow", "tmrw", "tmr"],
        dayAfterTomorrow: ["the day after tomorrow", "day after tomorrow"],
        weekdays: [
            ["sunday"], ["monday", "mon"], ["tuesday", "tues", "tue"], ["wednesday", "weds"],
            ["thursday", "thurs", "thur", "thu"], ["friday", "fri"], ["saturday"],
        ],
        months: [
            ["january", "jan"], ["february", "feb"], ["march", "mar"], ["april", "apr"], ["may"], ["june", "jun"],
            ["july", "jul"], ["august", "aug"], ["september", "sept", "sep"], ["october", "oct"],
            ["november", "nov"], ["december", "dec"],
        ],
        thisModifiers: ["this", "this coming", "coming"],
        nextModifiers: ["next"],
        thisWeek: ["this week", "end of the week", "end of this week", "end of week", "the end of the week", "later this week"],
        nextWeek: ["next week", "sometime next week", "early next week"],
        thisWeekend: ["this weekend", "the weekend", "weekend"],
        nextWeekend: ["next weekend"],
        thisMonth: ["this month", "later this month"],
        nextMonth: ["next month"],
        endOfMonth: ["end of the month", "end of this month", "end of month", "the end of the month", "month end"],
        endOfDay: ["end of day", "end of the day", "eod", "close of business", "cob", "end of business"],
        morning: ["this morning", "in the morning", "morning"],
        afternoon: ["this afternoon", "in the afternoon", "afternoon"],
        evening: ["in the evening", "evening"],
        noon: ["noon", "midday"],
        midnight: ["midnight"],
        vague: ["soon", "sometime", "at some point", "later", "when i can", "asap", "as soon as possible", "shortly"],
        coupleOfDays: ["in a couple of days", "in a couple days", "in two days or so"],
        fewDays: ["in a few days", "in the next few days", "in a few days time"],
        eventLinked: [
            "after the meeting", "before the meeting", "after our meeting", "before our meeting",
            "after the call", "before the call", "after our call", "before our call",
            "next time we talk", "next time we meet", "next time we speak", "next time i see",
            "when we meet", "when we talk", "when we speak", "when i see",
        ],
        prepositions: ["no later than", "by", "on", "before", "until", "till", "for", "due"],
        timePrepositions: ["at", "around", "by", "before"],
        amMarkers: ["am", "a.m.", "a.m", "in the morning"],
        pmMarkers: ["pm", "p.m.", "p.m", "in the afternoon", "in the evening", "at night", "tonight"],
        numberWords: [["one"], ["two"], ["three"], ["four"], ["five"], ["six"], ["seven"], ["eight"], ["nine"], ["ten"], ["eleven"], ["twelve"]],
        inWord: ["in"],
        dayUnits: ["day", "days"],
        weekUnits: ["week", "weeks"],
        monthUnits: ["month", "months"],
        hourUnits: ["hour", "hours", "hr", "hrs"],
        minuteUnits: ["minute", "minutes", "min", "mins"],
        articleOne: ["a", "an", "one"]
    )

    /// Partial Polish lexicon. Not exposed to users until extraction quality is
    /// validated for Polish (PRD §18); exercised by tests to keep parsing language-agnostic.
    public static let polish = DateLexicon(
        languageCode: "pl",
        today: ["dzis", "dzisiaj"],
        tonight: ["dzis wieczorem", "wieczorem"],
        tomorrow: ["jutro"],
        dayAfterTomorrow: ["pojutrze"],
        weekdays: [
            ["niedziela", "niedziele", "niedzieli"], ["poniedzialek", "poniedzialku"], ["wtorek", "wtorku"],
            ["sroda", "srode", "srody"], ["czwartek", "czwartku"], ["piatek", "piatku"], ["sobota", "sobote", "soboty"],
        ],
        months: [
            ["stycznia", "styczen"], ["lutego", "luty"], ["marca", "marzec"], ["kwietnia", "kwiecien"], ["maja", "maj"],
            ["czerwca", "czerwiec"], ["lipca", "lipiec"], ["sierpnia", "sierpien"], ["wrzesnia", "wrzesien"],
            ["pazdziernika", "pazdziernik"], ["listopada", "listopad"], ["grudnia", "grudzien"],
        ],
        thisModifiers: ["w ten", "w te", "ten", "te"],
        nextModifiers: ["w przyszly", "w przyszla", "przyszly", "przyszla", "w nastepny", "nastepny"],
        thisWeek: ["w tym tygodniu", "do konca tygodnia"],
        nextWeek: ["w przyszlym tygodniu", "w nastepnym tygodniu"],
        thisWeekend: ["w ten weekend", "w weekend"],
        nextWeekend: ["w przyszly weekend"],
        thisMonth: ["w tym miesiacu"],
        nextMonth: ["w przyszlym miesiacu"],
        endOfMonth: ["do konca miesiaca", "na koniec miesiaca"],
        endOfDay: ["do konca dnia"],
        morning: ["rano"],
        afternoon: ["po poludniu"],
        evening: ["wieczorem"],
        noon: ["w poludnie", "poludnie"],
        midnight: ["o polnocy", "polnoc"],
        vague: ["wkrotce", "niedlugo", "kiedys"],
        coupleOfDays: ["za pare dni", "za kilka dni"],
        fewDays: ["w ciagu kilku dni"],
        eventLinked: ["po spotkaniu", "przed spotkaniem", "jak sie spotkamy", "nastepnym razem"],
        prepositions: ["do", "w", "we", "na", "przed"],
        timePrepositions: ["o", "okolo", "przed"],
        amMarkers: ["rano"],
        pmMarkers: ["po poludniu", "wieczorem"],
        numberWords: [["pierwszej"], ["drugiej"], ["trzeciej"], ["czwartej"], ["piatej"], ["szostej"], ["siodmej"], ["osmej"], ["dziewiatej"], ["dziesiatej"], ["jedenastej"], ["dwunastej"]],
        inWord: ["za"],
        dayUnits: ["dzien", "dni"],
        weekUnits: ["tydzien", "tygodnie", "tygodni"],
        monthUnits: ["miesiac", "miesiace", "miesiecy"],
        hourUnits: ["godzine", "godziny", "godzin"],
        minuteUnits: ["minute", "minuty", "minut"],
        articleOne: ["jeden", "jedna"]
    )

    public static func forLanguage(_ code: String?) -> DateLexicon {
        code?.lowercased().hasPrefix("pl") == true ? .polish : .english
    }
}
