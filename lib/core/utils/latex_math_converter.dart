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
    'limits': '',
    'nolimits': '',

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
    'T': 'ᵀ',
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

  static String convertMathExpression(
    String expr, {
    bool escapeForMarkdown = false,
  }) {
    var s = expr.trim();
    if (s.isEmpty) return s;

    // Replace blackboard bold \mathbb{R} -> ℝ
    s = s.replaceAllMapped(RegExp(r'\\mathbb\{([A-Za-z])\}'), (m) {
      final ch = m.group(1)!;
      return _blackboardBold[ch] ?? ch;
    });

    // Unwrap text/font macros: \text{...}, \mathrm{...}, \mathbf{...}, \operatorname{...}
    for (var pass = 0; pass < 3; pass++) {
      final next = s.replaceAllMapped(
        RegExp(r'\\(?:text|textbf|textit|textrm|mathrm|mathbf|mathit|mathcal|mathsf|mathtt|operatorname)\{([^{}]*)\}'),
        (m) => m.group(1) ?? '',
      );
      if (next == s) break;
      s = next;
    }

    // Handle \sqrt[n]{x} and \sqrt{x}
    s = s.replaceAllMapped(RegExp(r'\\sqrt\[([^{}\]]+)\]\{([^{}]*)\}'), (m) {
      final root = _tryMapAllChars(m.group(1)!.trim(), _superscripts) ?? '(${m.group(1)!.trim()})';
      final inner = m.group(2)!.trim();
      return inner.length <= 2 ? '$root√$inner' : '$root√($inner)';
    });
    for (var pass = 0; pass < 2; pass++) {
      final next = s.replaceAllMapped(RegExp(r'\\sqrt\{([^{}]*)\}'), (m) {
        final inner = m.group(1)!.trim();
        return inner.length <= 2 ? '√$inner' : '√($inner)';
      });
      if (next == s) break;
      s = next;
    }

    // Handle \frac{a}{b}, \dfrac{a}{b}, \tfrac{a}{b}
    for (var pass = 0; pass < 3; pass++) {
      final next = s.replaceAllMapped(
        RegExp(r'\\(?:d|t)?frac\{([^{}]*)\}\{([^{}]*)\}'),
        (m) {
          final numStr = m.group(1)!.trim();
          final denStr = m.group(2)!.trim();
          final numWrap = _needsParensInFraction(numStr) ? '($numStr)' : numStr;
          final denWrap = _needsParensInFraction(denStr) ? '($denStr)' : denStr;
          return '$numWrap/$denWrap';
        },
      );
      if (next == s) break;
      s = next;
    }

    // Replace escaped punctuation & spacing commands
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

    // Replace named LaTeX commands \cmd
    s = s.replaceAllMapped(RegExp(r'\\([A-Za-z]+)'), (m) {
      final cmd = m.group(1)!;
      final mapped = _commands[cmd];
      if (mapped == null) {
        return m.group(0)!;
      }
      return mapped;
    });

    // Convert superscripts ^{...} and ^x
    s = s.replaceAllMapped(RegExp(r'\^\{([^{}]+)\}'), (m) {
      final inner = m.group(1)!.trim();
      final mapped = _tryMapAllChars(inner, _superscripts);
      return mapped ?? '^($inner)';
    });
    s = s.replaceAllMapped(RegExp(r'\^([0-9+\-=()A-Za-z])'), (m) {
      final ch = m.group(1)!;
      return _superscripts[ch] ?? '^$ch';
    });

    // Convert subscripts _{...} and _x
    s = s.replaceAllMapped(RegExp(r'_\{([^{}]+)\}'), (m) {
      final inner = m.group(1)!.trim();
      final mapped = _tryMapAllChars(inner, _subscripts);
      return mapped ?? '_$inner';
    });
    s = s.replaceAllMapped(RegExp(r'_([0-9+\-=()a-z])'), (m) {
      final ch = m.group(1)!;
      return _subscripts[ch] ?? '_$ch';
    });

    // Clean up remaining unescaped grouping braces {x} -> x
    for (var pass = 0; pass < 2; pass++) {
      final next = s.replaceAllMapped(RegExp(r'\{([^{}]*)\}'), (m) => m.group(1) ?? '');
      if (next == s) break;
      s = next;
    }

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
