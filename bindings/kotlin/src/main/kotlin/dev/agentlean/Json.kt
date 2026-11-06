package dev.agentlean

/**
 * A minimal JSON reader/writer, enough to read effects and build events without pulling a JSON
 * library into the AAR. Objects parse to [LinkedHashMap] (member order kept), arrays to [List],
 * integers to [Long] (or [java.math.BigInteger] when they do not fit), other numbers to [Double].
 */
object Json {
    class ParseException(message: String) : IllegalArgumentException(message)

    fun parse(text: String): Any? {
        val p = Parser(text)
        p.ws()
        val v = p.value()
        p.ws()
        if (p.i != text.length) p.fail("trailing characters")
        return v
    }

    /** The raw JSON text of each member of a top-level object, in order (no re-serialization). */
    fun members(text: String): LinkedHashMap<String, String> {
        val p = Parser(text)
        val out = LinkedHashMap<String, String>()
        p.ws()
        p.expect('{')
        p.ws()
        if (p.peek() == '}') { p.i++; return out }
        while (true) {
            p.ws()
            val key = p.string()
            p.ws(); p.expect(':'); p.ws()
            val start = p.i
            p.value()
            out[key] = text.substring(start, p.i)
            p.ws()
            when (p.next()) {
                ',' -> continue
                '}' -> return out
                else -> p.fail("expected ',' or '}'")
            }
        }
    }

    /** A JSON string literal for [s]. */
    fun quote(s: String): String {
        val b = StringBuilder(s.length + 2)
        b.append('"')
        for (c in s) {
            when (c) {
                '"' -> b.append("\\\"")
                '\\' -> b.append("\\\\")
                '\n' -> b.append("\\n")
                '\r' -> b.append("\\r")
                '\t' -> b.append("\\t")
                '\b' -> b.append("\\b")
                '\u000C' -> b.append("\\f")
                else -> if (c < ' ') b.append(String.format("\\u%04x", c.code)) else b.append(c)
            }
        }
        return b.append('"').toString()
    }

    /** Serialize maps, lists, strings, numbers, booleans and null. */
    fun write(v: Any?): String = StringBuilder().also { write(v, it) }.toString()

    private fun write(v: Any?, b: StringBuilder) {
        when (v) {
            null -> b.append("null")
            is String -> b.append(quote(v))
            is Boolean, is Int, is Long, is Short, is Byte, is java.math.BigInteger -> b.append(v.toString())
            is Number -> {
                val d = v.toDouble()
                require(!d.isNaN() && !d.isInfinite()) { "JSON cannot represent $d" }
                b.append(v.toString())
            }
            is Map<*, *> -> {
                b.append('{')
                var first = true
                for ((k, x) in v) {
                    if (!first) b.append(',')
                    first = false
                    b.append(quote(k.toString())).append(':')
                    write(x, b)
                }
                b.append('}')
            }
            is Iterable<*> -> {
                b.append('[')
                var first = true
                for (x in v) {
                    if (!first) b.append(',')
                    first = false
                    write(x, b)
                }
                b.append(']')
            }
            is Array<*> -> write(v.asList(), b)
            else -> throw IllegalArgumentException("cannot write ${v::class} as JSON")
        }
    }

    private class Parser(val s: String) {
        var i = 0

        fun fail(msg: String): Nothing = throw ParseException("json: $msg at $i")
        fun peek(): Char = if (i < s.length) s[i] else fail("unexpected end of input")
        fun next(): Char = peek().also { i++ }
        fun expect(c: Char) { if (next() != c) { i--; fail("expected '$c'") } }
        fun ws() { while (i < s.length && (s[i] == ' ' || s[i] == '\n' || s[i] == '\r' || s[i] == '\t')) i++ }

        fun value(): Any? = when (peek()) {
            '{' -> obj()
            '[' -> arr()
            '"' -> string()
            't' -> lit("true", true)
            'f' -> lit("false", false)
            'n' -> lit("null", null)
            else -> number()
        }

        fun lit(word: String, v: Any?): Any? {
            if (!s.startsWith(word, i)) fail("unexpected token")
            i += word.length
            return v
        }

        fun obj(): Map<String, Any?> {
            expect('{')
            val m = LinkedHashMap<String, Any?>()
            ws()
            if (peek() == '}') { i++; return m }
            while (true) {
                ws()
                val k = string()
                ws(); expect(':'); ws()
                m[k] = value()
                ws()
                when (next()) {
                    ',' -> {}
                    '}' -> return m
                    else -> { i--; fail("expected ',' or '}'") }
                }
            }
        }

        fun arr(): List<Any?> {
            expect('[')
            val l = ArrayList<Any?>()
            ws()
            if (peek() == ']') { i++; return l }
            while (true) {
                ws()
                l.add(value())
                ws()
                when (next()) {
                    ',' -> {}
                    ']' -> return l
                    else -> { i--; fail("expected ',' or ']'") }
                }
            }
        }

        fun string(): String {
            expect('"')
            val b = StringBuilder()
            while (true) {
                val c = next()
                when {
                    c == '"' -> return b.toString()
                    c == '\\' -> when (val e = next()) {
                        '"' -> b.append('"'); '\\' -> b.append('\\'); '/' -> b.append('/')
                        'b' -> b.append('\b'); 'f' -> b.append('\u000C'); 'n' -> b.append('\n')
                        'r' -> b.append('\r'); 't' -> b.append('\t')
                        'u' -> {
                            if (i + 4 > s.length) fail("bad \\u escape")
                            val code = s.substring(i, i + 4).toIntOrNull(16) ?: fail("bad \\u escape")
                            b.append(code.toChar())
                            i += 4
                        }
                        else -> fail("bad escape '\\$e'")
                    }
                    c < ' ' -> fail("control character in string")
                    else -> b.append(c)
                }
            }
        }

        fun number(): Any {
            val start = i
            if (i < s.length && s[i] == '-') i++
            var integral = true
            while (i < s.length) {
                val c = s[i]
                if (c in '0'..'9') i++
                else if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { integral = false; i++ }
                else break
            }
            val t = s.substring(start, i)
            if (t.isEmpty() || t == "-") fail("unexpected token")
            return if (integral) t.toLongOrNull() ?: java.math.BigInteger(t)
            else t.toDoubleOrNull() ?: fail("bad number '$t'")
        }
    }
}

/** Standard base64 (RFC 4648, padded); java.util.Base64 needs Android API 26 and minSdk is 24. */
internal object Base64Codec {
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    fun encode(data: ByteArray): String {
        val b = StringBuilder((data.size + 2) / 3 * 4)
        var i = 0
        while (i + 2 < data.size) {
            val n = (data[i].toInt() and 0xff shl 16) or (data[i + 1].toInt() and 0xff shl 8) or (data[i + 2].toInt() and 0xff)
            b.append(ALPHABET[n shr 18 and 63]).append(ALPHABET[n shr 12 and 63])
                .append(ALPHABET[n shr 6 and 63]).append(ALPHABET[n and 63])
            i += 3
        }
        val rest = data.size - i
        if (rest == 1) {
            val n = data[i].toInt() and 0xff shl 16
            b.append(ALPHABET[n shr 18 and 63]).append(ALPHABET[n shr 12 and 63]).append("==")
        } else if (rest == 2) {
            val n = (data[i].toInt() and 0xff shl 16) or (data[i + 1].toInt() and 0xff shl 8)
            b.append(ALPHABET[n shr 18 and 63]).append(ALPHABET[n shr 12 and 63])
                .append(ALPHABET[n shr 6 and 63]).append('=')
        }
        return b.toString()
    }

    fun decode(text: String): ByteArray {
        val clean = text.trimEnd('=')
        val out = java.io.ByteArrayOutputStream(clean.length * 3 / 4)
        var buf = 0
        var bits = 0
        for (c in clean) {
            val v = ALPHABET.indexOf(c)
            require(v >= 0) { "invalid base64 character '$c'" }
            buf = (buf shl 6) or v
            bits += 6
            if (bits >= 8) {
                bits -= 8
                out.write(buf shr bits and 0xff)
            }
        }
        return out.toByteArray()
    }
}
