import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';
import 'package:re_highlight/re_highlight.dart' show Mode;

// Grammars (re_highlight ships one generated `Mode` per language).
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/http.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/properties.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';

// Token color maps. Tokyo Night pairs with the DARKROOM/OLED chrome (it's the
// same palette as the terminal's "warp" theme); Atom One Light pairs with PAPER.
import 'package:re_highlight/styles/atom-one-light.dart';
import 'package:re_highlight/styles/tokyo-night-dark.dart';

import 'app_theme.dart';

/// Syntax-highlighting wiring for the code editor.
///
/// re_editor delegates tokenizing to re_highlight: it highlights with the
/// single language registered in [CodeHighlightTheme.languages] (an empty map
/// means "no highlighting", which is why the editor used to render every file
/// in one flat color). We register exactly the grammar that matches the open
/// file's extension and pair it with a token theme that follows the active
/// light/dark chrome.
class CodeHighlight {
  CodeHighlight._();

  /// language id -> generated grammar. The id is also the key re_highlight
  /// highlights with, so it just needs to be stable, not canonical.
  static final Map<String, Mode> _grammars = {
    'dart': langDart,
    'markdown': langMarkdown,
    'json': langJson,
    'yaml': langYaml,
    'python': langPython,
    'javascript': langJavascript,
    'typescript': langTypescript,
    'bash': langBash,
    'shell': langShell,
    'xml': langXml,
    'css': langCss,
    'scss': langScss,
    'c': langC,
    'cpp': langCpp,
    'java': langJava,
    'go': langGo,
    'rust': langRust,
    'sql': langSql,
    'kotlin': langKotlin,
    'swift': langSwift,
    'ini': langIni,
    'dockerfile': langDockerfile,
    'php': langPhp,
    'ruby': langRuby,
    'properties': langProperties,
    'lua': langLua,
    'makefile': langMakefile,
    'diff': langDiff,
    'http': langHttp,
    'graphql': langGraphql,
  };

  /// Lowercased file extension (no dot) -> language id in [_grammars].
  static const Map<String, String> _extToLang = {
    'dart': 'dart',
    'md': 'markdown',
    'markdown': 'markdown',
    'mdx': 'markdown',
    'json': 'json',
    'jsonc': 'json',
    'yaml': 'yaml',
    'yml': 'yaml',
    'py': 'python',
    'pyw': 'python',
    'js': 'javascript',
    'mjs': 'javascript',
    'cjs': 'javascript',
    'jsx': 'javascript',
    'ts': 'typescript',
    'tsx': 'typescript',
    'sh': 'bash',
    'bash': 'bash',
    'zsh': 'bash',
    'xml': 'xml',
    'html': 'xml',
    'htm': 'xml',
    'xhtml': 'xml',
    'svg': 'xml',
    'plist': 'xml',
    'css': 'css',
    'scss': 'scss',
    'sass': 'scss',
    'c': 'c',
    'h': 'c',
    'cpp': 'cpp',
    'cc': 'cpp',
    'cxx': 'cpp',
    'hpp': 'cpp',
    'hh': 'cpp',
    'java': 'java',
    'go': 'go',
    'rs': 'rust',
    'sql': 'sql',
    'kt': 'kotlin',
    'kts': 'kotlin',
    'swift': 'swift',
    'ini': 'ini',
    'toml': 'ini',
    'cfg': 'ini',
    'conf': 'ini',
    'php': 'php',
    'rb': 'ruby',
    'properties': 'properties',
    'env': 'properties',
    'lua': 'lua',
    'diff': 'diff',
    'patch': 'diff',
    'http': 'http',
    'graphql': 'graphql',
    'gql': 'graphql',
  };

  /// Returns the highlight theme for [filename] paired with the active chrome
  /// brightness, or `null` when the file type is unknown (the editor then falls
  /// back to its flat [CodeEditorStyle.textColor]).
  static CodeHighlightTheme? themeFor(String filename) {
    final id = _languageId(filename);
    final grammar = id == null ? null : _grammars[id];
    if (id == null || grammar == null) return null;

    final base = AppColors.brightness == Brightness.light
        ? atomOneLightTheme
        : tokyoNightDarkTheme;

    return CodeHighlightTheme(
      languages: {id: CodeHighlightThemeMode(mode: grammar)},
      theme: _markdownPolish(base),
    );
  }

  /// Resolves a language id from the file name: a couple of extension-less
  /// build files by name, otherwise by extension.
  static String? _languageId(String filename) {
    final base = filename.split('/').last.toLowerCase();
    if (base == 'dockerfile' || base.endsWith('.dockerfile')) {
      return 'dockerfile';
    }
    if (base == 'makefile' || base == 'gnumakefile') return 'makefile';

    final dot = base.lastIndexOf('.');
    if (dot < 0) return null;
    return _extToLang[base.substring(dot + 1)];
  }

  /// Headings (`section`) read as plain colored text in the stock themes; bold
  /// them so a `.md` file looks like a real markdown editor. Returns [base]
  /// untouched when it has no heading token.
  static Map<String, TextStyle> _markdownPolish(Map<String, TextStyle> base) {
    final section = base['section'];
    if (section == null) return base;
    return {
      ...base,
      'section': section.copyWith(fontWeight: FontWeight.bold),
    };
  }
}
