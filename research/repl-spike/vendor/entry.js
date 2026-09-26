export {EditorView, basicSetup} from "codemirror";
export {keymap, ViewPlugin, Decoration} from "@codemirror/view";
export {autocompletion, startCompletion, closeCompletion, currentCompletions, selectedCompletionIndex, completionStatus} from "@codemirror/autocomplete";
export {StreamLanguage, syntaxHighlighting, defaultHighlightStyle, HighlightStyle} from "@codemirror/language";
export {clojure} from "@codemirror/legacy-modes/mode/clojure";
export {insertNewlineAndIndent, history} from "@codemirror/commands";
export {Prec, RangeSetBuilder} from "@codemirror/state";
export {tags} from "@lezer/highlight";
