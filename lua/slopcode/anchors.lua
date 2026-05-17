-- SPDX-License-Identifier: MIT

--- Hashline-anchored editing: stateless hash computation and anchor validation.
---
--- When we read a file, each line gets a hash anchor prefix
--- (e.g. "1ab§line content"). Edit calls then reference these anchors
--- instead of repeating old code.
---
--- Format: LINETAG§content  (e.g. "5ab§local x = 1")
--- - LINETAG: line number + 2-char BPE bigram hash (e.g. "5ab")
--- - §: content separator
--- - content: the actual line content
---
--- For structural-only lines (whitespace + braces), the hash is an ordinal
--- suffix (1st, 2nd, 3rd, 4th, 11th, …) which BPE-merges with the line
--- number into a single token.
---
--- Design based on oh-my-pi's hashline system:
---   https://github.com/can1357/oh-my-pi
---   https://dirac.run/posts/hash-anchors-myers-diff-single-token
---
--- Order is stable — changing it would invalidate every saved anchor
--- reference in transcripts and prompts.

local M = {}

local to_lines = require('slopcode.utils.text').to_lines

local HASHLINE_BIGRAMS = {
    'aa',
    'ab',
    'ac',
    'ad',
    'ae',
    'af',
    'ag',
    'ah',
    'ai',
    'aj',
    'ak',
    'al',
    'am',
    'an',
    'ao',
    'ap',
    'aq',
    'ar',
    'as',
    'at',
    'au',
    'av',
    'aw',
    'ax',
    'ay',
    'az',
    'ba',
    'bb',
    'bc',
    'bd',
    'be',
    'bf',
    'bg',
    'bh',
    'bi',
    'bj',
    'bk',
    'bl',
    'bm',
    'bn',
    'bo',
    'bp',
    'bq',
    'br',
    'bs',
    'bt',
    'bu',
    'bv',
    'bw',
    'bx',
    'by',
    'bz',
    'ca',
    'cb',
    'cc',
    'cd',
    'ce',
    'cf',
    'cg',
    'ch',
    'ci',
    'cj',
    'ck',
    'cl',
    'cm',
    'cn',
    'co',
    'cp',
    'cq',
    'cr',
    'cs',
    'ct',
    'cu',
    'cv',
    'cw',
    'cx',
    'cy',
    'cz',
    'da',
    'db',
    'dc',
    'dd',
    'de',
    'df',
    'dg',
    'dh',
    'di',
    'dj',
    'dk',
    'dl',
    'dm',
    'dn',
    'do',
    'dp',
    'dq',
    'dr',
    'ds',
    'dt',
    'du',
    'dv',
    'dw',
    'dx',
    'dy',
    'dz',
    'ea',
    'eb',
    'ec',
    'ed',
    'ee',
    'ef',
    'eg',
    'eh',
    'ei',
    'ej',
    'ek',
    'el',
    'em',
    'en',
    'eo',
    'ep',
    'eq',
    'er',
    'es',
    'et',
    'eu',
    'ev',
    'ew',
    'ex',
    'ey',
    'ez',
    'fa',
    'fb',
    'fc',
    'fd',
    'fe',
    'ff',
    'fg',
    'fh',
    'fi',
    'fj',
    'fk',
    'fl',
    'fm',
    'fn',
    'fo',
    'fp',
    'fq',
    'fr',
    'fs',
    'ft',
    'fu',
    'fv',
    'fw',
    'fx',
    'fy',
    'fz',
    'ga',
    'gb',
    'gc',
    'gd',
    'ge',
    'gf',
    'gg',
    'gh',
    'gi',
    'gj',
    'gk',
    'gl',
    'gm',
    'gn',
    'go',
    'gp',
    'gq',
    'gr',
    'gs',
    'gt',
    'gu',
    'gv',
    'gw',
    'gx',
    'gy',
    'gz',
    'ha',
    'hb',
    'hc',
    'hd',
    'he',
    'hf',
    'hg',
    'hh',
    'hi',
    'hj',
    'hk',
    'hl',
    'hm',
    'hn',
    'ho',
    'hp',
    'hq',
    'hr',
    'hs',
    'ht',
    'hu',
    'hv',
    'hw',
    'hx',
    'hy',
    'hz',
    'ia',
    'ib',
    'ic',
    'id',
    'ie',
    'if',
    'ig',
    'ih',
    'ii',
    'ij',
    'ik',
    'il',
    'im',
    'in',
    'io',
    'ip',
    'iq',
    'ir',
    'is',
    'it',
    'iu',
    'iv',
    'iw',
    'ix',
    'iy',
    'iz',
    'ja',
    'jb',
    'jc',
    'jd',
    'je',
    'jf',
    'jg',
    'jh',
    'ji',
    'jj',
    'jk',
    'jl',
    'jm',
    'jn',
    'jo',
    'jp',
    'jq',
    'jr',
    'js',
    'jt',
    'ju',
    'jv',
    'jw',
    'jx',
    'jy',
    'jz',
    'ka',
    'kb',
    'kc',
    'kd',
    'ke',
    'kf',
    'kg',
    'kh',
    'ki',
    'kj',
    'kk',
    'kl',
    'km',
    'kn',
    'ko',
    'kp',
    'kq',
    'kr',
    'ks',
    'kt',
    'ku',
    'kv',
    'kw',
    'kx',
    'ky',
    'kz',
    'la',
    'lb',
    'lc',
    'ld',
    'le',
    'lf',
    'lg',
    'lh',
    'li',
    'lj',
    'lk',
    'll',
    'lm',
    'ln',
    'lo',
    'lp',
    'lq',
    'lr',
    'ls',
    'lt',
    'lu',
    'lv',
    'lw',
    'lx',
    'ly',
    'lz',
    'ma',
    'mb',
    'mc',
    'md',
    'me',
    'mf',
    'mg',
    'mh',
    'mi',
    'mj',
    'mk',
    'ml',
    'mm',
    'mn',
    'mo',
    'mp',
    'mq',
    'mr',
    'ms',
    'mt',
    'mu',
    'mv',
    'mw',
    'mx',
    'my',
    'mz',
    'na',
    'nb',
    'nc',
    'nd',
    'ne',
    'nf',
    'ng',
    'nh',
    'ni',
    'nj',
    'nk',
    'nl',
    'nm',
    'nn',
    'no',
    'np',
    'nq',
    'nr',
    'ns',
    'nt',
    'nu',
    'nv',
    'nw',
    'nx',
    'ny',
    'nz',
    'oa',
    'ob',
    'oc',
    'od',
    'oe',
    'of',
    'og',
    'oh',
    'oi',
    'oj',
    'ok',
    'ol',
    'om',
    'on',
    'oo',
    'op',
    'oq',
    'or',
    'os',
    'ot',
    'ou',
    'ov',
    'ow',
    'ox',
    'oy',
    'oz',
    'pa',
    'pb',
    'pc',
    'pd',
    'pe',
    'pf',
    'pg',
    'ph',
    'pi',
    'pj',
    'pk',
    'pl',
    'pm',
    'pn',
    'po',
    'pp',
    'pq',
    'pr',
    'ps',
    'pt',
    'pu',
    'pv',
    'pw',
    'px',
    'py',
    'pz',
    'qa',
    'qb',
    'qc',
    'qd',
    'qe',
    'qf',
    'qg',
    'qh',
    'qi',
    'qj',
    'qk',
    'ql',
    'qm',
    'qn',
    'qo',
    'qp',
    'qq',
    'qr',
    'qs',
    'qt',
    'qu',
    'qv',
    'qw',
    'qx',
    'qy',
    'qz',
    'ra',
    'rb',
    'rc',
    'rd',
    're',
    'rf',
    'rg',
    'rh',
    'ri',
    'rj',
    'rk',
    'rl',
    'rm',
    'rn',
    'ro',
    'rp',
    'rq',
    'rr',
    'rs',
    'rt',
    'ru',
    'rv',
    'rw',
    'rx',
    'ry',
    'rz',
    'sa',
    'sb',
    'sc',
    'sd',
    'se',
    'sf',
    'sg',
    'sh',
    'si',
    'sj',
    'sk',
    'sl',
    'sm',
    'sn',
    'so',
    'sp',
    'sq',
    'sr',
    'ss',
    'st',
    'su',
    'sv',
    'sw',
    'sx',
    'sy',
    'sz',
    'ta',
    'tb',
    'tc',
    'td',
    'te',
    'tf',
    'tg',
    'th',
    'ti',
    'tj',
    'tk',
    'tl',
    'tm',
    'tn',
    'to',
    'tp',
    'tq',
    'tr',
    'ts',
    'tt',
    'tu',
    'tv',
    'tw',
    'tx',
    'ty',
    'tz',
    'ua',
    'ub',
    'uc',
    'ud',
    'ue',
    'uf',
    'ug',
    'uh',
    'ui',
    'uj',
    'uk',
    'ul',
    'um',
    'un',
    'uo',
    'up',
    'uq',
    'ur',
    'us',
    'ut',
    'uu',
    'uv',
    'uw',
    'ux',
    'uy',
    'uz',
    'va',
    'vb',
    'vc',
    'vd',
    've',
    'vf',
    'vg',
    'vh',
    'vi',
    'vj',
    'vk',
    'vl',
    'vm',
    'vn',
    'vo',
    'vp',
    'vq',
    'vr',
    'vs',
    'vt',
    'vu',
    'vv',
    'vw',
    'vx',
    'vy',
    'vz',
    'wa',
    'wb',
    'wc',
    'wd',
    'we',
    'wf',
    'wg',
    'wh',
    'wi',
    'wj',
    'wk',
    'wl',
    'wm',
    'wn',
    'wo',
    'wp',
    'wq',
    'wr',
    'ws',
    'wt',
    'wu',
    'wv',
    'ww',
    'wx',
    'wy',
    'wz',
    'xa',
    'xb',
    'xc',
    'xd',
    'xe',
    'xf',
    'xg',
    'xh',
    'xi',
    'xj',
    'xk',
    'xl',
    'xm',
    'xn',
    'xo',
    'xp',
    'xq',
    'xr',
    'xs',
    'xt',
    'xu',
    'xv',
    'xw',
    'xx',
    'xy',
    'xz',
    'ya',
    'yb',
    'yc',
    'yd',
    'ye',
    'yf',
    'yg',
    'yh',
    'yi',
    'yj',
    'yk',
    'yl',
    'ym',
    'yn',
    'yo',
    'yp',
    'yq',
    'yr',
    'ys',
    'yt',
    'yu',
    'yv',
    'yw',
    'yx',
    'yy',
    'yz',
    'za',
    'zb',
    'zc',
    'zd',
    'ze',
    'zf',
    'zg',
    'zh',
    'zi',
    'zj',
    'zk',
    'zl',
    'zm',
    'zn',
    'zo',
    'zp',
    'zq',
    'zr',
    'zs',
    'zt',
    'zu',
    'zv',
    'zw',
    'zx',
    'zy',
    'zz',
}

local HASHLINE_BIGRAMS_COUNT = #HASHLINE_BIGRAMS
local BIGRAM_SET = {}
for _, bg in ipairs(HASHLINE_BIGRAMS) do
    BIGRAM_SET[bg] = true
end
local SEPARATOR = '§'
local LINE_HASH = '(%d+)(%l%l)' -- captures line number + 2-letter hash
local MARKERS = '[>+%-]' -- optional prefix markers (>>>, +, -)
local HASHLINE_PREFIX_RE = '^[^' .. SEPARATOR .. ']*' .. SEPARATOR
local REBASE_WINDOW = 5
local MISMATCH_CONTEXT = 2

--- FNV-1a 32-bit hash.
--- @param s string
--- @param seed? integer
--- @return integer
local function fnv1a(s, seed)
    local h = seed or 0x811c9dc5
    for i = 1, #s do
        h = bit.bxor(h, string.byte(s, i))
        h = (h * 0x01000193) % 0x100000000
    end
    return h
end

--- Normalize Unicode variations
--- @param s string
--- @return string
local function normalize_unicode(s)
    s = s:gsub('%s+$', '') -- trim trailing whitespace
    -- Smart quotes → straight quotes
    s = s:gsub('\u{2018}', "'"):gsub('\u{2019}', "'")
    s = s:gsub('\u{201C}', '"'):gsub('\u{201D}', '"')
    -- Em/en dashes → hyphens
    s = s:gsub('\u{2013}', '-'):gsub('\u{2014}', '-')
    -- Non-breaking spaces → regular spaces
    s = s:gsub('\u{00A0}', ' ')
    return s
end

--- Parse an anchor reference (e.g. "5ab", ">>> 5ab", "+5ab|content").
--- @param ref string  anchor reference
--- @return integer line  1-indexed line number
--- @return string hash  2-char BPE bigram
local function parse_anchor_ref(ref)
    local line, hash = M.parse(ref)
    if line then
        if line < 1 then
            error('[E_BAD_REF] Line number must be >= 1, got ' .. line .. ' in "' .. ref .. '".', 0)
        end
        if not BIGRAM_SET[hash] then
            error('[E_BAD_REF] Invalid hash "' .. hash .. '" in "' .. ref .. '". Not in bigram alphabet.', 0)
        end
        return line, hash
    end
    -- line is nil — check for hash-only or full failure
    if hash then
        error(
            '[E_BAD_REF] Invalid anchor "'
                .. ref
                .. '". It looks like you supplied only the 2-letter suffix ("'
                .. hash
                .. '"). Copy the full anchor exactly as shown (line number + suffix, e.g. "5'
                .. hash
                .. '" = "5'
                .. hash
                .. '").',
            0
        )
    end
    error('[E_BAD_REF] Invalid anchor "' .. ref .. '". Expected line number + 2-letter hash (e.g. "5ab").', 0)
end

--- Try to find the requested hash within ±window lines of the anchor line.
--- Skips the anchor line itself (caller already knows it doesn't match).
--- Returns the new line number when exactly one nearby line matches;
--- returns nil if no match or ambiguous (more than one match).
--- @param file_lines string[]  1-indexed array of file lines
--- @param anchor_line integer  original line number from the anchor
--- @param hash_str string  expected hash
--- @param window? integer  search radius (default REBASE_WINDOW)
--- @return integer? line  rebased line number, or nil
local function try_rebase_anchor(file_lines, anchor_line, hash_str, window)
    window = window or REBASE_WINDOW
    local lo = math.max(1, anchor_line - window)
    local hi = math.min(#file_lines, anchor_line + window)
    local found = nil
    for i = lo, hi do
        if i ~= anchor_line then
            if M.hash(i, file_lines[i]) == hash_str then
                if found ~= nil then
                    return nil -- ambiguous: more than one match
                end
                found = i
            end
        end
    end
    return found
end

--- Format a stale-anchor recovery message with current anchors for retry.
--- Shows MISMATCH_CONTEXT lines around each mismatched anchor, with `>>>` marker
--- on the originally-referenced line and current hashline anchors for context.
--- @param file_lines string[]  1-indexed array of file lines
--- @param mismatches AnchorResult[]  Failed results from validate_anchors
--- @return string recovery_message
local function format_mismatches(file_lines, mismatches)
    local parts = {}
    parts[#parts + 1] = '[E_STALE_ANCHOR] ' .. #mismatches .. ' stale anchor(s). Retry with the >>> anchors below.'
    for _, m in ipairs(mismatches) do
        local line = m.line
        if line then
            local start = math.max(1, line - MISMATCH_CONTEXT)
            local end_line = math.min(#file_lines, line + MISMATCH_CONTEXT)
            for i = start, end_line do
                local prefix = (i == line) and '>>> ' or '    '
                parts[#parts + 1] = prefix .. M.format(i, file_lines[i])
            end
        end
    end
    return table.concat(parts, '\n')
end

--- Normalize line endings: \r\n → \n, standalone \r → \n.
local function normalize_lf(text)
    return text:gsub('\r\n', '\n'):gsub('\r', '\n')
end

--- Detect original line ending from content.
local function detect_line_ending(content)
    if content:find('\r\n', 1, true) then
        return '\r\n'
    end
    return '\n'
end

--- Restore original line endings after applying edits.
local function restore_line_endings(text, ending)
    if ending == '\r\n' then
        return text:gsub('\n', '\r\n')
    end
    return text
end

--- Strip UTF-8 BOM.
local function strip_bom(content)
    if content:sub(1, 3) == '\xEF\xBB\xBF' then
        return '\xEF\xBB\xBF', content:sub(4)
    end
    return '', content
end

--- Auto-absorb boundary duplication: replacement lines that duplicate adjacent
--- surviving file lines are absorbed into the edit range instead of being
--- duplicated. Returns widened edits and warnings.
--- @param file_lines string[] 1-indexed original file lines
--- @param resolved table[] sorted resolved edits with start_line, end_line, repl_lines
--- @return table[] widened resolved edits
--- @return string[] warnings
local function absorb_boundary_duplicates(file_lines, resolved)
    local warnings = {}
    -- Collect all target lines across edits to avoid absorbing lines
    -- that belong to another edit's range.
    local all_targets = {}
    for _, r in ipairs(resolved) do
        for ln = r.start_line, r.end_line do
            all_targets[ln] = true
        end
    end

    -- Deduplicate warnings by range key
    local emitted_keys = {}

    local widened = {}
    for i, r in ipairs(resolved) do
        local start_line = r.start_line
        local end_line = r.end_line
        local repl_lines = r.repl_lines

        -- Check prefix: do the replacement's first lines match the file lines immediately before the range?
        if #repl_lines > 0 and start_line > 1 then
            local prefix_count = 0
            local max_prefix = math.min(#repl_lines, start_line - 1)
            for count = max_prefix, 2, -1 do
                local matches = true
                for offset = 0, count - 1 do
                    local file_line = file_lines[start_line - count + offset] or ''
                    local repl_line = repl_lines[offset + 1] or ''
                    if file_line ~= repl_line then
                        matches = false
                        break
                    end
                end
                if matches then
                    -- Check that none of the to-be-absorbed lines are targeted by another edit
                    local safe = true
                    for offset = 0, count - 1 do
                        if all_targets[start_line - count + offset] then
                            safe = false
                            break
                        end
                    end
                    if safe then
                        prefix_count = count
                        break
                    end
                end
            end
            if prefix_count > 0 then
                local key = 'prefix:' .. (start_line - prefix_count) .. '..' .. (start_line - 1)
                if not emitted_keys[key] then
                    emitted_keys[key] = true
                    warnings[#warnings + 1] = 'Auto-absorbed '
                        .. prefix_count
                        .. ' duplicate line(s) before edit '
                        .. i
                        .. ': file lines '
                        .. (start_line - prefix_count)
                        .. '..'
                        .. (start_line - 1)
                        .. ' matched the replacement leading lines; widened deletion to absorb them.'
                end
                start_line = start_line - prefix_count
            end
        end

        -- Check suffix: do the replacement's last lines match the file lines immediately after the range?
        if #repl_lines > 0 and end_line < #file_lines then
            local suffix_count = 0
            local max_suffix = math.min(#repl_lines, #file_lines - end_line)
            for count = max_suffix, 2, -1 do
                local matches = true
                for offset = 0, count - 1 do
                    local file_line = file_lines[end_line + 1 + offset] or ''
                    local repl_line = repl_lines[#repl_lines - count + 1 + offset] or ''
                    if file_line ~= repl_line then
                        matches = false
                        break
                    end
                end
                if matches then
                    -- Check that none of the to-be-absorbed lines are targeted by another edit
                    local safe = true
                    for offset = 0, count - 1 do
                        if all_targets[end_line + 1 + offset] then
                            safe = false
                            break
                        end
                    end
                    if safe then
                        suffix_count = count
                        break
                    end
                end
            end
            if suffix_count > 0 then
                local key = 'suffix:' .. (end_line + 1) .. '..' .. (end_line + suffix_count)
                if not emitted_keys[key] then
                    emitted_keys[key] = true
                    warnings[#warnings + 1] = 'Auto-absorbed '
                        .. suffix_count
                        .. ' duplicate line(s) after edit '
                        .. i
                        .. ': file lines '
                        .. (end_line + 1)
                        .. '..'
                        .. (end_line + suffix_count)
                        .. ' matched the replacement trailing lines; widened deletion to absorb them.'
                end
                end_line = end_line + suffix_count
            end
        end

        widened[#widened + 1] = {
            start_line = start_line,
            end_line = end_line,
            repl_lines = repl_lines,
        }
    end
    return widened, warnings
end

--- Find the changed line range between old and new file content
--- using prefix/suffix scanning — no string concatenation or diff needed.
local function changed_range(old_lines, new_lines)
    local old_n, new_n = #old_lines, #new_lines
    local min_n = math.min(old_n, new_n)
    local prefix = 0
    while prefix < min_n and old_lines[prefix + 1] == new_lines[prefix + 1] do
        prefix = prefix + 1
    end
    if prefix == old_n and old_n == new_n then
        return nil, nil
    end
    local suffix = 0
    while suffix < min_n - prefix and old_lines[old_n - suffix] == new_lines[new_n - suffix] do
        suffix = suffix + 1
    end
    local first_changed = prefix + 1
    local last_changed = new_n - suffix
    if last_changed < first_changed then
        if first_changed <= new_n then
            last_changed = first_changed
        else
            return nil, nil
        end
    end
    return first_changed, last_changed
end

--- Validate an anchor against file content.
--- Tries exact match first, then fuzzy Unicode normalization,
--- then auto-rebase (search ±REBASE_WINDOW lines for matching hash).
--- Always returns the parsed line number (even on failure) so callers can
--- use it for error context without re-parsing.
--- @param file_lines string[]  1-indexed array of file lines
--- @param anchor string  anchor reference like "5ab"
--- @return boolean valid
--- @return integer? line_num  resolved line number (may differ if rebased); nil only on parse error
--- @return string? msg  nil on exact match; "FUZZY_MATCH" or "REBASED" on soft success; error message on failure
local function validate_anchor(file_lines, anchor)
    local line, hash_str = parse_anchor_ref(anchor)
    if line > #file_lines then
        return false, line, 'Line ' .. line .. ' does not exist (file has ' .. #file_lines .. ' lines).'
    end
    local actual = M.hash(line, file_lines[line])
    if actual == hash_str then
        return true, line
    end
    -- Fuzzy: try with Unicode normalization on the file line
    local normalized = normalize_unicode(file_lines[line])
    local fuzzy_hash = M.hash(line, normalized)
    if fuzzy_hash == hash_str then
        return true, line, 'FUZZY_MATCH'
    end
    -- Auto-rebase: search ±REBASE_WINDOW lines for a matching hash
    local rebased = try_rebase_anchor(file_lines, line, hash_str)
    if rebased then
        return true, rebased, 'REBASED'
    end
    return false,
        line,
        'Stale anchor: line '
            .. line
            .. ' hash is '
            .. actual
            .. ', not '
            .. hash_str
            .. '. The file has changed since your last read.'
end

--- Result of validating a single anchor.
--- @class AnchorResult
--- @field anchor string  Original anchor reference (e.g. "5ab")
--- @field valid boolean  Whether the anchor resolved successfully
--- @field line integer?  Resolved line number (present even on stale-match failure; nil only on parse error)
--- @field msg string?  nil on exact match; "FUZZY_MATCH" or "REBASED" on soft success; error message on failure

--- Batch-validate a list of anchors against file content.
--- Returns results for all anchors plus a collected list of stale mismatches.
--- @param file_lines string[]  1-indexed array of file lines
--- @param anchors_list string[]  List of anchor references like "5ab"
--- @return AnchorResult[] results  One result per anchor, in order
--- @return AnchorResult[] mismatches  Only the failed results (for error reporting)
local function validate_anchors(file_lines, anchors_list)
    local results = {}
    local mismatches = {}
    for _, anchor in ipairs(anchors_list) do
        local valid, line, msg = validate_anchor(file_lines, anchor)
        local result = { anchor = anchor, valid = valid, line = line, msg = msg }
        results[#results + 1] = result
        if not valid then
            mismatches[#mismatches + 1] = result
        end
    end
    return results, mismatches
end

--- Compute the 2-character BPE bigram hash for a line at a given number.
--- Structural lines (whitespace + braces only) get ordinal suffixes.
--- Non-significant lines (no alphanumeric) are seeded with line number.
--- @param idx integer  1-indexed line number
--- @param line string  line content
--- @return string hash  2-char bigram from HASHLINE_BIGRAMS
function M.hash(idx, line)
    local trimmed = line:gsub('%s+$', '')
    -- Structural lines: whitespace + braces only → ordinal suffix
    if trimmed:gsub('[%s{}]', '') == '' then
        local mod100 = idx % 100
        if mod100 >= 11 and mod100 <= 13 then
            return 'th'
        end
        local mod10 = idx % 10
        if mod10 == 1 then
            return 'st'
        elseif mod10 == 2 then
            return 'nd'
        elseif mod10 == 3 then
            return 'rd'
        end
        return 'th'
    end

    local seed = 0
    if not trimmed:find('[%a%d]') then
        seed = idx
    end
    return HASHLINE_BIGRAMS[(fnv1a(trimmed, seed) % HASHLINE_BIGRAMS_COUNT) + 1]
end

--- Format a single line with its hash anchor prefix.
--- @param idx integer  1-indexed line number
--- @param line string  raw line content
--- @return string  e.g. "5ab§local x = 1"
function M.format(idx, line)
    return idx .. M.hash(idx, line) .. SEPARATOR .. line
end

--- Parse a hashline-formatted line or anchor reference into its components.
--- Tries, in order: formatted display line ("5ab§content"),
--- raw reference ("5ab", ">>> 5ab"), and hash-only ("ab").
--- @param line string  Formatted line or anchor reference
--- @return number? line_num
--- @return string? hash
--- @return string? content content after § (display format), or the original line on failure
function M.parse(line)
    -- Try formatted display line: "5ab§content"
    local line_num, hash, content = line:match('^' .. LINE_HASH .. SEPARATOR .. '(.*)$')
    if line_num then
        return tonumber(line_num), hash, content
    end
    -- Try raw reference with optional markers: "5ab", ">>> 5ab"
    local line_str, hash_str = line:match('^%s*' .. MARKERS .. '*%s*' .. LINE_HASH)
    if line_str then
        return tonumber(line_str), hash_str
    end
    -- Try hash-only: "ab"
    local hash_only = line:match('^%s*' .. MARKERS .. '*%s*(%l%l)%s*$')
    if hash_only then
        return nil, hash_only
    end
    return nil, nil, line
end

--- Strip hashline display prefixes from an array of lines.
--- If a line starts with a hashline prefix (anything before §), strip it once.
--- @param lines string[]  Array of lines to strip
--- @return string[]  Lines with prefixes removed where applicable
function M.strip(lines)
    local result = {}
    for _, line in ipairs(lines) do
        result[#result + 1] = line:gsub(HASHLINE_PREFIX_RE, '')
    end
    return result
end

--- Apply anchor-based edits to file content.
--- Takes raw file text, handles BOM, line-ending normalization, anchor validation,
--- edit application, boundary absorption, and line-ending restoration internally.
--- Pure function — no I/O, no Neovim dependency.
--- @param file_text string Raw file content (may have BOM, CRLF, etc.)
--- @param edits table[] Each edit: { start_anchor: string, end_anchor: string, repl_lines: string[] }
--- @return table result { text: string, lines: string[], first_changed: integer?, last_changed: integer?, warnings: string[] }
function M.apply_edits(file_text, edits)
    if not edits or #edits == 0 then
        error('edits must contain at least one replacement.', 0)
    end
    local bom, text = strip_bom(file_text)
    local ending = detect_line_ending(text)
    local normalized = normalize_lf(text)
    local file_lines = to_lines(normalized)
    local resolved = {}
    local warnings = {}

    for i, edit in ipairs(edits) do
        local start_anchor = edit.start_anchor
        local end_anchor = edit.end_anchor
        if not start_anchor or start_anchor == '' then
            error('edits[' .. (i - 1) .. '].start_anchor is required', 0)
        end
        if not end_anchor or end_anchor == '' then
            error('edits[' .. (i - 1) .. '].end_anchor is required', 0)
        end
        local repl_lines = edit.repl_lines or {}

        -- Batch-validate both anchors before proceeding
        local results, mismatches = validate_anchors(file_lines, { start_anchor, end_anchor })
        local start_result = results[1]
        local end_result = results[2]

        if #mismatches > 0 then
            error(mismatches[1].msg .. '\n' .. format_mismatches(file_lines, mismatches), 0)
        end

        local start_line = start_result.line
        local end_line = end_result.line

        if start_result.msg == 'FUZZY_MATCH' then
            warnings[#warnings + 1] = 'edits[' .. (i - 1) .. '].start_anchor: fuzzy Unicode match (normalized)'
        elseif start_result.msg == 'REBASED' then
            warnings[#warnings + 1] = 'edits['
                .. (i - 1)
                .. '].start_anchor: auto-rebased '
                .. start_anchor
                .. ' → '
                .. start_line
                .. M.hash(start_line, file_lines[start_line])
                .. ' (line shifted within ±'
                .. REBASE_WINDOW
                .. '; hash matched)'
        end
        if end_result.msg == 'FUZZY_MATCH' then
            warnings[#warnings + 1] = 'edits[' .. (i - 1) .. '].end_anchor: fuzzy Unicode match (normalized)'
        elseif end_result.msg == 'REBASED' then
            warnings[#warnings + 1] = 'edits['
                .. (i - 1)
                .. '].end_anchor: auto-rebased '
                .. end_anchor
                .. ' → '
                .. end_line
                .. M.hash(end_line, file_lines[end_line])
                .. ' (line shifted within ±'
                .. REBASE_WINDOW
                .. '; hash matched)'
        end

        if start_line > end_line then
            error(
                'edits['
                    .. (i - 1)
                    .. ']: start_anchor (line '
                    .. start_line
                    .. ') is after end_anchor (line '
                    .. end_line
                    .. ')',
                0
            )
        end

        resolved[#resolved + 1] = {
            start_line = start_line,
            end_line = end_line,
            repl_lines = repl_lines,
        }
    end

    -- Sort by start_line to check for overlaps
    table.sort(resolved, function(a, b)
        return a.start_line < b.start_line
    end)

    for i = 2, #resolved do
        local prev = resolved[i - 1]
        local cur = resolved[i]
        if prev.end_line >= cur.start_line then
            error(
                'edits overlap: one edit covers lines '
                    .. prev.start_line
                    .. '-'
                    .. prev.end_line
                    .. ' and another covers '
                    .. cur.start_line
                    .. '-'
                    .. cur.end_line
                    .. '. Merge them or target disjoint ranges.',
                0
            )
        end
    end

    -- Auto-absorb boundary duplicates
    local widened, boundary_warnings = absorb_boundary_duplicates(file_lines, resolved)
    for _, w in ipairs(boundary_warnings) do
        warnings[#warnings + 1] = w
    end
    resolved = widened

    -- Build result in a single forward pass
    local new_lines = {}
    local src = 1

    for _, r in ipairs(resolved) do
        for i = src, r.start_line - 1 do
            new_lines[#new_lines + 1] = file_lines[i]
        end
        for _, line in ipairs(r.repl_lines) do
            new_lines[#new_lines + 1] = normalize_lf(line)
        end
        src = r.end_line + 1
    end

    for i = src, #file_lines do
        new_lines[#new_lines + 1] = file_lines[i]
    end

    -- Compute changed range
    local first_changed, last_changed = changed_range(file_lines, new_lines)

    -- Rejoin and restore line endings
    local new_text = table.concat(new_lines, '\n')
    new_text = restore_line_endings(new_text, ending)
    new_text = bom .. new_text

    return {
        text = new_text,
        lines = new_lines,
        first_changed = first_changed,
        last_changed = last_changed,
        warnings = warnings,
    }
end

return M
