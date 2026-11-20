/// The open-check outcomes prompt cards' answer steps are gated on.
class CardChecks {
  const CardChecks({this.fileAndMcpNotes = false, this.persistOptions = false, this.previewNotes = false,
      this.webFetch = false, this.singleOther = false});
  final bool fileAndMcpNotes; // Yes/No with a note on Write, Edit, MCP: paste and Enter
  final bool persistOptions; // rule and mode rows: "always allow", "don't ask again", "switch to auto mode", plan auto, bypass
  final bool previewNotes; // n, paste, Enter on a preview option (at Mac width and at 45 columns)
  final bool webFetch; // every WebFetch answer; its No row reads "No, and tell Claude what to do differently (esc)"
  final bool singleOther; // Enter after pasting into a single-choice Other field at 45 columns (seen only at 100)
}

const cardChecks = CardChecks(); // all unproven until Task 9
