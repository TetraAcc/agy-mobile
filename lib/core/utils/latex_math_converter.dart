/// Lightweight LaTeX math expression normalizer for Markdown text.
///
/// Converts inline (`$...$`, `\(...\)`) and display (`$$...$$`, `\[...\]`)
/// LaTeX math expressions into clean, readable Unicode mathematical notation
/// while preserving fenced code blocks (` ``` `) and inline code spans (`` ` ``)
/// untouched and escaping any residual underscores/asterisks inside math so
/// CommonMark does not misinterpret them as italics.
class LatexMathConverter {
  static const Map<String, String> _commands = {
    // Functions & operators
    'min': 'min',
    'max': 'max',
    'sup': 'sup',
    'inf': 'inf',
    'lim': 'lim',
    'limsup': 'lim sup',
    'liminf': 'lim inf',
    'log': 'log',
    'ln': 'ln',
    'lg': 'lg',
    'exp': 'exp',
    'sin': 'sin',
    'cos': 'cos',
    'tan': 'tan',
    'cot': 'cot',
    'sec': 'sec',
    'csc': 'csc',
    'arcsin': 'arcsin',
    'arccos': 'arccos',
    'arctan': 'arctan',
    'sinh': 'sinh',
    'cosh': 'cosh',
    'tanh': 'tanh',
    'arg': 'arg',
    'deg': 'deg',
    'det': 'det',
    'dim': 'dim',
    'gcd': 'gcd',
    'hom': 'hom',
    'ker': 'ker',
    'Pr': 'Pr',
    'mod': 'mod',
    'bmod': ' mod ',
    'pmod': ' mod ',

    // Comparisons & relations
    'ge': '≥',
    'geq': '≥',
    'geqslant': '≥',
    'le': '≤',
    'leq': '≤',
    'leqslant': '≤',
    'ne': '≠',
    'neq': '≠',
    'approx': '≈',
    'cong': '≅',
    'equiv': '≡',
    'sim': '∼',
    'simeq': '≃',
    'propto': '∝',
    'll': '≪',
    'gg': '≫',
    'prec': '≺',
    'succ': '≻',
    'preceq': '≼',
    'succeq': '≽',
    'perp': '⊥',
    'parallel': '∥',
    'mid': '|',
    'nmid': '∤',

    // Arithmetic & binary operators
    'times': '×',
    'div': '÷',
    'pm': '±',
    'mp': '∓',
    'cdot': '·',
    'ast': '*',
    'star': '⋆',
    'circ': '∘',
    'bullet': '•',
    'oplus': '⊕',
    'ominus': '⊖',
    'otimes': '⊗',
    'odot': '⊙',

    // Arrows
    'to': '→',
    'rightarrow': '→',
    'longrightarrow': '→',
    'leftarrow': '←',
    'gets': '←',
    'longleftarrow': '←',
    'leftrightarrow': '↔',
    'longleftrightarrow': '↔',
    'Rightarrow': '⇒',
    'Longrightarrow': '⇒',
    'implies': '⇒',
    'Leftarrow': '⇐',
    'Longleftarrow': '⇐',
    'impliedby': '⇐',
    'Leftrightarrow': '⇔',
    'Longleftrightarrow': '⇔',
    'iff': '⇔',
    'uparrow': '↑',
    'downarrow': '↓',
    'updownarrow': '↕',
    'mapsto': '↦',
    'longmapsto': '↦',

    // Sets & logic
    'in': '∈',
    'notin': '∉',
    'ni': '∋',
    'subset': '⊂',
    'supset': '⊃',
    'subseteq': '⊆',
    'supseteq': '⊇',
    'subsetneq': '⊊',
    'supsetneq': '⊋',
    'cup': '∪',
    'cap': '∩',
    'bigcup': '⋃',
    'bigcap': '⋂',
    'setminus': '∖',
    'emptyset': '∅',
    'varnothing': '∅',
    'forall': '∀',
    'exists': '∃',
    'nexists': '∄',
    'neg': '¬',
    'lnot': '¬',
    'land': '∧',
    'wedge': '∧',
    'lor': '∨',
    'vee': '∨',
    'therefore': '∴',
    'because': '∵',

    // Calculus, big operators & symbols
    'infty': '∞',
    'partial': '∂',
    'nabla': '∇',
    'hbar': 'ℏ',
    'ell': 'ℓ',
    'wp': '℘',
    'Re': 'ℜ',
    'Im': 'ℑ',
    'sum': '∑',
    'prod': '∏',
    'coprod': '∐',
    'int': '∫',
    'iint': '∬',
    'iiint': '∭',
    'oint': '∮',
    'dots': '…',
    'ldots': '…',
    'cdots': '⋯',
    'vdots': '⋮',
    'ddots': '⋱',
    'angle': '∠',
    'triangle': '△',
    'degree': '°',
    'prime': '′',
    'langle': '⟨',
    'rangle': '⟩',
    'lceil': '⌈',
    'rceil': '⌉',
    'lfloor': '⌊',
    'rfloor': '⌋',
    'quad': '  ',
    'qquad': '    ',
    'colon': ':',

    // Sizing / delimiter modifiers (strip cleanly)
    'left': '',
    'right': '',
    'big': '',
    'Big': '',
    'bigg': '',
    'Bigg': '',
    'bigl': '',
    'bigr': '',
    'Bigl': '',
    'Bigr': '',
    'displaystyle': '',
    'textstyle': '',
    'scriptstyle': '',
    'scriptscriptstyle': '',
    'limits': '',
    'nolimits': '',
    'bf': '',
    'rm': '',
    'it': '',
    'sf': '',
    'tt': '',
    'cal': '',
    'sl': '',
    'sc': '',
    'bfseries': '',
    'rmfamily': '',
    'itshape': '',
    'mathbf': '',
    'mathrm': '',
    'mathit': '',
    'mathcal': '',
    'mathsf': '',
    'mathtt': '',
    'mathfrak': '',
    'mathscr': '',
    'mathnormal': '',
    'boldsymbol': '',
    'bm': '',
    'pmb': '',
    'text': '',
    'textbf': '',
    'textit': '',
    'textrm': '',
    'textsf': '',
    'texttt': '',
    'operatorname': '',
    'boxed': '',
    'mbox': '',
    'hbox': '',
    'emph': '',
    'underline': '',
    'phantom': '',

    // Greek letters (lowercase)
    'alpha': 'α',
    'beta': 'β',
    'gamma': 'γ',
    'delta': 'δ',
    'epsilon': 'ε',
    'varepsilon': 'ε',
    'zeta': 'ζ',
    'eta': 'η',
    'theta': 'θ',
    'vartheta': 'θ',
    'iota': 'ι',
    'kappa': 'κ',
    'lambda': 'λ',
    'mu': 'μ',
    'nu': 'ν',
    'xi': 'ξ',
    'pi': 'π',
    'varpi': 'π',
    'rho': 'ρ',
    'varrho': 'ρ',
    'sigma': 'σ',
    'varsigma': 'σ',
    'tau': 'τ',
    'upsilon': 'υ',
    'phi': 'φ',
    'varphi': 'φ',
    'chi': 'χ',
    'psi': 'ψ',
    'omega': 'ω',

    // Greek letters (uppercase)
    'Gamma': 'Γ',
    'Delta': 'Δ',
    'Theta': 'Θ',
    'Lambda': 'Λ',
    'Xi': 'Ξ',
    'Pi': 'Π',
    'Sigma': 'Σ',
    'Upsilon': 'Υ',
    'Phi': 'Φ',
    'Psi': 'Ψ',
    'Omega': 'Ω',
  };

  static const Map<String, String> _blackboardBold = {
    'N': 'ℕ',
    'Z': 'ℤ',
    'Q': 'ℚ',
    'R': 'ℝ',
    'C': 'ℂ',
    'P': 'ℙ',
    'E': '𝔼',
  };

  static const Map<String, String> _subscripts = {
    '0': '₀',
    '1': '₁',
    '2': '₂',
    '3': '₃',
    '4': '₄',
    '5': '₅',
    '6': '₆',
    '7': '₇',
    '8': '₈',
    '9': '₉',
    '+': '₊',
    '-': '₋',
    '=': '₌',
    '(': '₍',
    ')': '₎',
    'a': 'ₐ',
    'e': 'ₑ',
    'h': 'ₕ',
    'i': 'ᵢ',
    'j': 'ⱼ',
    'k': 'ₖ',
    'l': 'ₗ',
    'm': 'ₘ',
    'n': 'ₙ',
    'o': 'ₒ',
    'p': 'ₚ',
    'r': 'ᵣ',
    's': 'ₛ',
    't': 'ₜ',
    'u': 'ᵤ',
    'v': 'ᵥ',
    'x': 'ₓ',
  };

  static const Map<String, String> _superscripts = {
    '0': '⁰',
    '1': '¹',
    '2': '²',
    '3': '³',
    '4': '⁴',
    '5': '⁵',
    '6': '⁶',
    '7': '⁷',
    '8': '⁸',
    '9': '⁹',
    '+': '⁺',
    '-': '⁻',
    '=': '⁼',
    '(': '⁽',
    ')': '⁾',
    'a': 'ᵃ',
    'b': 'ᵇ',
    'c': 'ᶜ',
    'd': 'ᵈ',
    'e': 'ᵉ',
    'f': 'ᶠ',
    'g': 'ᵍ',
    'h': 'ʰ',
    'i': 'ⁱ',
    'j': 'ʲ',
    'k': 'ᵏ',
    'l': 'ˡ',
    'm': 'ᵐ',
    'n': 'ⁿ',
    'o': 'ᵒ',
    'p': 'ᵖ',
    'r': 'ʳ',
    's': 'ˢ',
    't': 'ᵗ',
    'u': 'ᵘ',
    'v': 'ᵛ',
    'w': 'ʷ',
    'x': 'ˣ',
    'y': 'ʸ',
    'z': 'ᶻ',
    'A': 'ᴬ',
    'B': 'ᴮ',
    'D': 'ᴰ',
    'E': 'ᴱ',
    'G': 'ᴳ',
    'H': 'ᴴ',
    'I': 'ᴵ',
    'J': 'ᴶ',
    'K': 'ᴷ',
    'L': 'ᴸ',
    'M': 'ᴹ',
    'N': 'ᴺ',
    'O': 'ᴼ',
    'P': 'ᴾ',
    'R': 'ᴿ',
    'T': 'ᵀ',
    'U': 'ᵁ',
    'V': 'ⱽ',
    'W': 'ᵂ',
  };

  // Matches fenced code blocks (```...``` or ~~~...~~~) or inline code spans (`...`).
  static final RegExp _codeBlockOrSpanRe = RegExp(
    r'(```[\s\S]*?```|~~~[\s\S]*?~~~|`+[^`\n]+`+)',
    multiLine: true,
  );

  // Matches display math $$...$$ or \[...\]
  static final RegExp _displayMathRe = RegExp(
    r'\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]',
    multiLine: true,
  );

  // Matches inline math \(...\)
  static final RegExp _parenInlineMathRe = RegExp(
    r'\\\(([^\n]+?)\\\)',
  );

  // Matches inline math $...$ adhering to Pandoc/KaTeX boundary rules:
  // - Not preceded by `\` or `$` or alphanumeric/digit directly attached to currency
  // - Opening `$` not followed by whitespace or `$`
  // - Closing `$` not preceded by whitespace or `\` and not followed by a digit
  static final RegExp _dollarInlineMathRe = RegExp(
    r'(?<![\\\$])\$(?!\s|\$)([^\$\n]*?[^\s\\\$])\$(?![0-9\$])|(?<![\\\$])\$([^\s\$\n])\$(?![0-9\$])',
  );

  static String normalizeMarkdownMath(String input) {
    if (input.isEmpty) return input;
    if (!input.contains(r'$') && !input.contains(r'\')) return input;

    final buf = StringBuffer();
    var lastEnd = 0;
    for (final match in _codeBlockOrSpanRe.allMatches(input)) {
      if (match.start > lastEnd) {
        buf.write(_convertNonCodeSegment(input.substring(lastEnd, match.start)));
      }
      buf.write(match.group(0));
      lastEnd = match.end;
    }
    if (lastEnd < input.length) {
      buf.write(_convertNonCodeSegment(input.substring(lastEnd)));
    }
    return buf.toString();
  }

  static String _convertNonCodeSegment(String segment) {
    var out = segment;

    // 1. Display math $$...$$ and \[...\]
    out = out.replaceAllMapped(_displayMathRe, (m) {
      final body = (m.group(1) ?? m.group(2) ?? '').trim();
      if (body.isEmpty) return m.group(0)!;
      return convertMathExpression(body, escapeForMarkdown: true);
    });

    // 2. Inline \(...\)
    out = out.replaceAllMapped(_parenInlineMathRe, (m) {
      final body = (m.group(1) ?? '').trim();
      if (body.isEmpty) return m.group(0)!;
      return convertMathExpression(body, escapeForMarkdown: true);
    });

    // 3. Inline $...$
    out = out.replaceAllMapped(_dollarInlineMathRe, (m) {
      final body = (m.group(1) ?? m.group(2) ?? '').trim();
      if (body.isEmpty) return m.group(0)!;
      return convertMathExpression(body, escapeForMarkdown: true);
    });

    return out;
  }

  static const Set<String> _unwrapSingleArgMacros = {
    'text',
    'textbf',
    'textit',
    'textrm',
    'textsf',
    'texttt',
    'mathrm',
    'mathbf',
    'mathit',
    'mathcal',
    'mathsf',
    'mathtt',
    'mathfrak',
    'mathscr',
    'mathnormal',
    'boldsymbol',
    'bm',
    'pmb',
    'operatorname',
    'boxed',
    'mbox',
    'hbox',
    'emph',
    'underline',
    'phantom',
  };

  static const Set<String> _accentMacros = {
    'vec',
    'overline',
    'bar',
    'hat',
    'widehat',
    'tilde',
    'widetilde',
    'dot',
    'ddot',
  };

  /// Read one `{...}` group starting at [start] (allowing leading whitespace),
  /// handling nested balanced braces and escaped `\{` / `\}`.
  static ({String content, int nextIndex})? _readBraceGroup(String s, int start) {
    var i = start;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
    if (i >= s.length || s[i] != '{') return null;
    final contentStart = i + 1;
    var depth = 0;
    while (i < s.length) {
      final ch = s[i];
      if (ch == r'\' && i + 1 < s.length) {
        i += 2;
        continue;
      }
      if (ch == '{') {
        depth++;
      } else if (ch == '}') {
        depth--;
        if (depth == 0) {
          return (content: s.substring(contentStart, i), nextIndex: i + 1);
        }
      }
      i++;
    }
    return null;
  }

  /// Read an optional `[...]` bracket group starting at [start].
  static ({String content, int nextIndex})? _readBracketGroup(String s, int start) {
    var i = start;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t')) {
      i++;
    }
    if (i >= s.length || s[i] != '[') return null;
    final contentStart = i + 1;
    var depth = 0;
    while (i < s.length) {
      final ch = s[i];
      if (ch == r'\' && i + 1 < s.length) {
        i += 2;
        continue;
      }
      if (ch == '[') {
        depth++;
      } else if (ch == ']') {
        depth--;
        if (depth == 0) {
          return (content: s.substring(contentStart, i), nextIndex: i + 1);
        }
      }
      i++;
    }
    return null;
  }

  static String _applyAccent(String macro, String inner) {
    final clean = inner.trim();
    if (clean.isEmpty) return '';
    switch (macro) {
      case 'vec':
        return clean.length <= 2 ? '$clean\u20D7' : 'vec($clean)';
      case 'bar':
        return clean.length == 1 ? '$clean\u0304' : _applyOverline(clean);
      case 'overline':
        return _applyOverline(clean);
      case 'hat':
      case 'widehat':
        return clean.length == 1 ? '$clean\u0302' : 'hat($clean)';
      case 'tilde':
      case 'widetilde':
        return clean.length == 1 ? '$clean\u0303' : '~$clean';
      case 'dot':
        return clean.length == 1 ? '$clean\u0307' : 'dot($clean)';
      case 'ddot':
        return clean.length == 1 ? '$clean\u0308' : 'ddot($clean)';
      default:
        return clean;
    }
  }

  static String _applyOverline(String text) {
    if (text.length == 1) return '$text\u0304';
    final buf = StringBuffer();
    for (final rune in text.runes) {
      final ch = String.fromCharCode(rune);
      buf.write(ch);
      if (ch.trim().isNotEmpty) {
        buf.write('\u0305');
      }
    }
    return buf.toString();
  }

  /// Recursively expand balanced-brace macros (`\mathbf{...}`, `\frac{a}{b}`,
  /// `\sqrt[n]{x}`, `\overline{...}`, `\vec{...}`, `\stackrel{a}{b}`, `\textcolor{c}{x}`, etc.).
  static String _expandBalancedMacros(String input, {int depth = 0}) {
    if (depth > 8 || !input.contains(r'\')) return input;
    final out = StringBuffer();
    var i = 0;

    while (i < input.length) {
      if (input[i] != r'\') {
        out.write(input[i]);
        i++;
        continue;
      }

      var cmdEnd = i + 1;
      while (cmdEnd < input.length &&
          ((input.codeUnitAt(cmdEnd) >= 65 && input.codeUnitAt(cmdEnd) <= 90) ||
              (input.codeUnitAt(cmdEnd) >= 97 && input.codeUnitAt(cmdEnd) <= 122))) {
        cmdEnd++;
      }
      if (cmdEnd == i + 1) {
        // Escaped non-letter symbol like \{ or \,
        if (i + 1 < input.length) {
          out.write(input.substring(i, i + 2));
          i += 2;
        } else {
          out.write(input[i]);
          i++;
        }
        continue;
      }

      final cmd = input.substring(i + 1, cmdEnd);

      // 1. \mathbb{R} -> ℝ
      if (cmd == 'mathbb') {
        final grp = _readBraceGroup(input, cmdEnd);
        if (grp != null) {
          final inner = _expandBalancedMacros(grp.content, depth: depth + 1).trim();
          out.write(_blackboardBold[inner] ?? inner);
          i = grp.nextIndex;
          continue;
        }
      }

      // 2. \color{red} (1 arg, strip) and \textcolor{red}{body} (2 args, keep body)
      if (cmd == 'color') {
        final grp = _readBraceGroup(input, cmdEnd);
        if (grp != null) {
          i = grp.nextIndex;
          continue;
        }
      }
      if (cmd == 'textcolor') {
        final colorGrp = _readBraceGroup(input, cmdEnd);
        final bodyGrp = colorGrp != null ? _readBraceGroup(input, colorGrp.nextIndex) : null;
        if (bodyGrp != null) {
          out.write(_expandBalancedMacros(bodyGrp.content, depth: depth + 1));
          i = bodyGrp.nextIndex;
          continue;
        }
      }

      // 3. Unwrap single-arg text/font/box macros even with arbitrary nested braces
      if (_unwrapSingleArgMacros.contains(cmd)) {
        final grp = _readBraceGroup(input, cmdEnd);
        if (grp != null) {
          out.write(_expandBalancedMacros(grp.content, depth: depth + 1));
          i = grp.nextIndex;
          continue;
        }
      }

      // 4. Accents: \vec{...}, \overline{...}, \bar{...}, \hat{...}, \tilde{...}, \dot{...}
      if (_accentMacros.contains(cmd)) {
        final grp = _readBraceGroup(input, cmdEnd);
        if (grp != null) {
          final inner = _expandBalancedMacros(grp.content, depth: depth + 1);
          out.write(_applyAccent(cmd, inner));
          i = grp.nextIndex;
          continue;
        }
      }

      // 5. \stackrel{top}{base}, \overset{top}{base}, \underset{bot}{base}
      if (cmd == 'stackrel' || cmd == 'overset' || cmd == 'underset') {
        final arg1 = _readBraceGroup(input, cmdEnd);
        final arg2 = arg1 != null ? _readBraceGroup(input, arg1.nextIndex) : null;
        if (arg1 != null && arg2 != null) {
          final label = _expandBalancedMacros(arg1.content, depth: depth + 1).trim();
          final base = _expandBalancedMacros(arg2.content, depth: depth + 1).trim();
          if (cmd != 'underset' && label == '?' && base == '=') {
            out.write('≟');
          } else if (cmd != 'underset' && (label == 'def' || label == r'\Delta' || label == 'Δ') && base == '=') {
            out.write('≜');
          } else if (label.isEmpty) {
            out.write(base);
          } else {
            out.write('$base($label)');
          }
          i = arg2.nextIndex;
          continue;
        }
      }

      // 6. \sqrt[n]{x} and \sqrt{x}
      if (cmd == 'sqrt') {
        final optBracket = _readBracketGroup(input, cmdEnd);
        final bodyGrp = _readBraceGroup(input, optBracket?.nextIndex ?? cmdEnd);
        if (bodyGrp != null) {
          final inner = _expandBalancedMacros(bodyGrp.content, depth: depth + 1).trim();
          final bodyText = inner.length <= 2 ? '√$inner' : '√($inner)';
          if (optBracket != null) {
            final rootRaw = _expandBalancedMacros(optBracket.content, depth: depth + 1).trim();
            final rootSup = _tryMapAllChars(rootRaw, _superscripts) ?? '($rootRaw)';
            out.write('$rootSup$bodyText');
          } else {
            out.write(bodyText);
          }
          i = bodyGrp.nextIndex;
          continue;
        }
      }

      // 7. \frac{a}{b}, \dfrac{a}{b}, \tfrac{a}{b}
      if (cmd == 'frac' || cmd == 'dfrac' || cmd == 'tfrac') {
        final numGrp = _readBraceGroup(input, cmdEnd);
        final denGrp = numGrp != null ? _readBraceGroup(input, numGrp.nextIndex) : null;
        if (numGrp != null && denGrp != null) {
          final numStr = _expandBalancedMacros(numGrp.content, depth: depth + 1).trim();
          final denStr = _expandBalancedMacros(denGrp.content, depth: depth + 1).trim();
          final numWrap = _needsParensInFraction(numStr) ? '($numStr)' : numStr;
          final denWrap = _needsParensInFraction(denStr) ? '($denStr)' : denStr;
          out.write('$numWrap/$denWrap');
          i = denGrp.nextIndex;
          continue;
        }
      }

      out.write(input.substring(i, cmdEnd));
      i = cmdEnd;
    }

    return out.toString();
  }

  static String convertMathExpression(
    String expr, {
    bool escapeForMarkdown = false,
  }) {
    var s = expr.trim();
    if (s.isEmpty) return s;

    // 1. Expand all balanced-brace macros (\mathbf{...}, \frac{a}{b}, \sqrt{x}, \overline{...}, \stackrel{?}{=}, etc.)
    s = _expandBalancedMacros(s);

    // 2. Replace escaped punctuation & spacing commands
    s = s
        .replaceAll(r'\{', '{')
        .replaceAll(r'\}', '}')
        .replaceAll(r'\%', '%')
        .replaceAll(r'\&', '&')
        .replaceAll(r'\#', '#')
        .replaceAll(r'\$', r'$')
        .replaceAll(r'\_', '_')
        .replaceAll(r'\,', ' ')
        .replaceAll(r'\;', ' ')
        .replaceAll(r'\:', ' ')
        .replaceAll(r'\!', '');

    // 3. Replace named LaTeX commands \cmd (strip trailing single space when mapped to empty string)
    s = s.replaceAllMapped(RegExp(r'\\([A-Za-z]+)( ?)'), (m) {
      final cmd = m.group(1)!;
      final trailingSpace = m.group(2) ?? '';
      final mapped = _commands[cmd];
      if (mapped == null) {
        return m.group(0)!;
      }
      if (mapped.isEmpty) {
        return '';
      }
      return '$mapped$trailingSpace';
    });

    // 4. Convert superscripts ^{...} and ^x
    s = s.replaceAllMapped(RegExp(r'\^\{([^{}]+)\}'), (m) {
      final inner = m.group(1)!.trim();
      final mapped = _tryMapAllChars(inner, _superscripts);
      return mapped ?? '^($inner)';
    });
    s = s.replaceAllMapped(RegExp(r'\^([0-9+\-=()A-Za-z])'), (m) {
      final ch = m.group(1)!;
      return _superscripts[ch] ?? '^$ch';
    });

    // 5. Convert subscripts _{...} and _x
    s = s.replaceAllMapped(RegExp(r'_\{([^{}]+)\}'), (m) {
      final inner = m.group(1)!.trim();
      final mapped = _tryMapAllChars(inner, _subscripts);
      return mapped ?? '_$inner';
    });
    s = s.replaceAllMapped(RegExp(r'_([0-9+\-=()a-z])'), (m) {
      final ch = m.group(1)!;
      return _subscripts[ch] ?? '_$ch';
    });

    // 6. Clean up remaining unescaped grouping braces {x} -> x
    for (var pass = 0; pass < 3; pass++) {
      final next = s.replaceAllMapped(RegExp(r'\{([^{}]*)\}'), (m) => m.group(1) ?? '');
      if (next == s) break;
      s = next;
    }

    // Collapse redundant spaces introduced by stripped layout commands
    s = s.replaceAll(RegExp(r' {2,}'), ' ');

    if (escapeForMarkdown) {
      // Escape any remaining underscores or asterisks inside the math output so
      // CommonMark doesn't swallow pairs of '_' or '*' as italics.
      s = s.replaceAll('_', r'\_').replaceAll('*', r'\*');
    }

    return s.trim();
  }

  static bool _needsParensInFraction(String part) {
    if (part.length <= 2) return false;
    return part.contains(' ') || part.contains('+') || part.contains('-');
  }

  static String? _tryMapAllChars(String text, Map<String, String> table) {
    if (text.isEmpty) return null;
    final buf = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (ch == ' ') continue;
      final mapped = table[ch];
      if (mapped == null) return null;
      buf.write(mapped);
    }
    return buf.toString();
  }
}
