import MWDATDisplay

enum TranslationDisplay {
  static func make(english: String, japanese: String) -> FlexBox {
    FlexBox(direction: .column, spacing: 16) {
      Text(english, style: .meta, color: .secondary)
      Text(japanese, style: .heading)
    }
    .padding(24)
  }
}

