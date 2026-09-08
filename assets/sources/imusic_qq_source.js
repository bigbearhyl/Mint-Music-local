/*!
 * @name iMusic-QQ音源
 * @description iMusic移植QQ音乐源：搜索/播放链接/歌词/封面，匿名可用
 * @version 1.0.0
 * @author bigbearhyl
 * @homepage https://github.com/kingmuchen/Mint-Music
 */

// ============================================================
// iMusic-QQ音源
// - musicUrl: CgiGetVkey 取直链，多文件名一次请求内部降级
// - musicSearch: DoSearchForQQMusicDesktop，失败回落旧版 client_search_cp
// - musicLyric: PlayLyricInfo(含翻译)，失败回落 fcg_query_lyric_new
// - musicPic: 专辑图 gtimg，无 albumMid 时搜索补齐
// 可选：把 QQ 登录 cookie 填到下面 COOKIE（如 qm_keyst=xxx; uin=o12345），
// 可解锁 320k/flac 更高成功率；留空则匿名（128k 为主）。
// ============================================================
var COOKIE = ''

var EVENT_NAMES = {
  request: 'request',
  inited: 'inited',
  updateAlert: 'updateAlert',
}

var UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
var BASE_HEADERS = {
  'User-Agent': UA,
  Referer: 'https://y.qq.com/',
}
if (COOKIE) BASE_HEADERS.Cookie = COOKIE

// 音质表（iMusic 同款）：格式名 -> [文件名前缀, 扩展名]
var FORMAT_MAP = {
  mp3_128: ['M500', '.mp3'],
  mp3_320: ['M800', '.mp3'],
  flac: ['F000', '.flac'],
  ogg640: ['O801', '.ogg'],
  ogg320: ['O800', '.ogg'],
  ogg192: ['O600', '.ogg'],
  acc192: ['C600', '.m4a'],
  acc96: ['C400', '.m4a'],
  master: ['AI00', '.flac'],
  atmos: ['Q000', '.flac'],
}
// 默认首选 ogg640（SQ无损OGG，O801）：2026-09 实测匿名可出链的最好音质；
// flac(F000)/master(AI00) 需绿钻，失败自动顺链降级。
// 注意：UrlGetVkey 批量文件名只有第一个会返回 purl，必须逐个音质请求。
var QUALITY_CHAINS = {
  '128k': ['ogg640', 'mp3_128', 'acc192', 'ogg320'],
  '192k': ['ogg640', 'acc192', 'ogg192', 'acc96'],
  '320k': ['ogg640', 'mp3_320', 'ogg320', 'acc192'],
  flac: ['flac', 'ogg640'],
  flac24bit: ['flac', 'ogg640'],
  hires: ['ogg640', 'flac'],
  atmos: ['ogg640', 'atmos'],
  master: ['ogg640', 'master'],
}
// 兜底：只要歌能听就尽量给出东西
var ULTIMATE_FALLBACK = ['ogg320', 'acc192', 'mp3_128']

function newGuid() {
  var n = Math.floor(Math.random() * 9000000000) + 1000000000
  return String(n)
}

function http(url, options) {
  options = options || {}
  var headers = {}
  var k
  for (k in BASE_HEADERS) headers[k] = BASE_HEADERS[k]
  if (options.headers) {
    for (k in options.headers) headers[k] = options.headers[k]
  }
  return new Promise(function (resolve, reject) {
    lx
      .request(url, {
        method: options.method || 'GET',
        headers: headers,
        body: options.body,
        timeout: options.timeout || 15000,
        follow_max: 5,
      })
      .then(
        function (resp) {
          if (resp.statusCode >= 200 && resp.statusCode < 400) {
            resolve(resp)
          } else {
            reject(new Error('HTTP ' + resp.statusCode))
          }
        },
        function (err) {
          reject(err instanceof Error ? err : new Error(String(err)))
        }
      )
  })
}

function musicu(reqId, module_, method, param) {
  var payload = {}
  payload.comm = {
    uin: 0,
    format: 'json',
    ct: 24,
    cv: 0,
    inCharset: 'utf-8',
    outCharset: 'utf-8',
    notice: 0,
    platform: 'yqq.json',
    needNewCode: 0,
  }
  var req = { module: module_, method: method, param: param }
  payload[reqId] = req
  return http('https://u.y.qq.com/cgi-bin/musicu.fcg', {
    method: 'POST',
    body: JSON.stringify(payload),
    headers: { 'Content-Type': 'application/json' },
  }).then(function (resp) {
    var body = resp.body
    if (typeof body === 'string') body = JSON.parse(body)
    var data = body[reqId]
    if (!data) throw new Error('响应缺少 ' + reqId)
    return data
  })
}

// ---------- base64 + utf8 纯 JS 解码（不依赖宿主 Buffer 实现） ----------
var B64_CHARS =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
var B64_LOOKUP = []
;(function () {
  for (var i = 0; i < B64_CHARS.length; i++) B64_LOOKUP[B64_CHARS.charAt(i)] = i
  B64_LOOKUP['-'] = 62
  B64_LOOKUP['_'] = 63
})()

function base64Decode(input) {
  var clean = String(input || '').replace(/[^A-Za-z0-9+/=_-]/g, '')
  var bytes = []
  var i = 0
  while (i < clean.length) {
    var a = B64_LOOKUP[clean.charAt(i)] || 0
    var b = B64_LOOKUP[clean.charAt(i + 1)] || 0
    var c = clean.charAt(i + 2) === '=' ? -1 : B64_LOOKUP[clean.charAt(i + 2)] || 0
    var d = clean.charAt(i + 3) === '=' ? -1 : B64_LOOKUP[clean.charAt(i + 3)] || 0
    bytes.push((a << 2) | (b >> 4))
    if (c >= 0) bytes.push(((b & 15) << 4) | (c >> 2))
    if (d >= 0) bytes.push(((c & 3) << 6) | d)
    i += 4
  }
  return utf8Decode(bytes)
}

function utf8Decode(bytes) {
  var out = ''
  var i = 0
  while (i < bytes.length) {
    var b = bytes[i]
    var code = 0
    if (b < 0x80) {
      code = b
      i += 1
    } else if ((b & 0xe0) === 0xc0) {
      code = ((b & 0x1f) << 6) | (bytes[i + 1] & 0x3f)
      i += 2
    } else if ((b & 0xf0) === 0xe0) {
      code =
        ((b & 0x0f) << 12) |
        ((bytes[i + 1] & 0x3f) << 6) |
        (bytes[i + 2] & 0x3f)
      i += 3
    } else if ((b & 0xf8) === 0xf0) {
      code =
        ((b & 0x07) << 18) |
        ((bytes[i + 1] & 0x3f) << 12) |
        ((bytes[i + 2] & 0x3f) << 6) |
        (bytes[i + 3] & 0x3f)
      i += 4
    } else {
      code = 0xfffd
      i += 1
    }
    if (code >= 0x10000) {
      code -= 0x10000
      out += String.fromCharCode(0xd800 + (code >> 10), 0xdc00 + (code & 0x3ff))
    } else {
      out += String.fromCharCode(code)
    }
  }
  return out
}

// ---------- 搜索 ----------
function formatInterval(sec) {
  sec = parseInt(sec, 10) || 0
  if (sec <= 0) return ''
  var m = Math.floor(sec / 60)
  var s = sec % 60
  return m + ':' + (s < 10 ? '0' : '') + s
}

function formatSize(bytes) {
  var n = parseInt(bytes, 10) || 0
  if (n <= 0) return ''
  var mb = n / 1024 / 1024
  return mb.toFixed(1) + 'M'
}

function buildTypes(file) {
  var types = []
  var typeMap = {}
  function add(type, size) {
    var human = formatSize(size)
    if (!human) return
    var entry = { type: type, size: human }
    types.push(entry)
    typeMap[type] = entry
  }
  add('128k', file && file.size_128mp3)
  add('192k', file && file.size_192mp3)
  add('320k', file && file.size_320mp3)
  add('flac', file && file.size_flac)
  add('hires', file && file.size_hires)
  return { types: types, typeMap: typeMap }
}

function mapDesktopSong(item) {
  var singer = (item.singer || [])
    .map(function (s) {
      return s.name
    })
    .join('、')
  var mediaMid =
    (item.file && item.file.mediaMid) || item.mid || ''
  var meta = buildTypes(item.file)
  return {
    songmid: item.mid,
    songId: item.id,
    name: item.name || item.title || '',
    singer: singer,
    source: 'tx',
    interval: formatInterval(item.interval),
    albumName: (item.album && item.album.name) || '',
    albumId: item.album && item.album.id,
    albumMid: item.album && item.album.mid,
    strMediaMid: mediaMid,
    img:
      item.album && item.album.mid
        ? 'https://y.gtimg.cn/music/photo_new/T002R500x500M000' +
          item.album.mid +
          '.jpg'
        : '',
    types: meta.types,
    _types: meta.typeMap,
  }
}

function mapLegacySong(item) {
  var singer = item.singer || ''
  if (Array.isArray(singer)) {
    singer = singer
      .map(function (s) {
        return s.name
      })
      .join('、')
  }
  var meta = buildTypes({
    size_128mp3: item.size128,
    size_320mp3: item.size320,
    size_flac: item.sizeflac,
  })
  return {
    songmid: item.songmid,
    songId: item.songid,
    name: item.songname || '',
    singer: String(singer),
    source: 'tx',
    interval: formatInterval(item.interval),
    albumName: item.albumname || '',
    albumId: item.albumid,
    albumMid: item.albummid,
    strMediaMid: item.strMediaMid || item.media_mid || item.songmid,
    img:
      item.albummid
        ? 'https://y.gtimg.cn/music/photo_new/T002R500x500M000' +
          item.albummid +
          '.jpg'
        : '',
    types: meta.types,
    _types: meta.typeMap,
  }
}

function searchDesktop(keyword, page, limit) {
  return musicu('req', 'music.search.SearchCgiService', 'DoSearchForQQMusicDesktop', {
    search_type: 0,
    query: keyword,
    page_num: page,
    num_per_page: limit,
    nqc_flag: 0,
  }).then(function (data) {
    if (data.code !== 0) throw new Error('搜索失败 code=' + data.code)
    var body = data.body || {}
    var list = (body.song && body.song.list) || body.item_song || []
    return {
      list: list.map(mapDesktopSong),
      total: (body.song && body.song.totalnum) || list.length,
      isEnd: list.length < limit,
    }
  })
}

function searchLegacy(keyword, page, limit) {
  var url =
    'https://c.y.qq.com/soso/fcgi-bin/client_search_cp' +
    '?ct=24&qqmusic_ver=1298&new_json=0&remoteplace=txt.yqq.song' +
    '&t=0&aggr=1&cr=1&catZhida=1&lossless=0&flag_qc=0' +
    '&p=' + page + '&n=' + limit + '&w=' + encodeURIComponent(keyword) +
    '&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf-8' +
    '&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0'
  return http(url).then(function (resp) {
    var body = resp.body
    if (typeof body === 'string') body = JSON.parse(body)
    var song = (body.data && body.data.song) || {}
    var list = song.list || []
    return {
      list: list.map(mapLegacySong),
      total: song.totalnum || list.length,
      isEnd: list.length < limit,
    }
  })
}

function handleSearch(info) {
  var keyword = info.keyword || ''
  var page = info.page || 1
  var limit = info.limit || info.pagesize || 30
  // 2026-09 实测：desktop 匿名搜索已返回空列表，旧版接口仍可用，故为主
  return searchLegacy(keyword, page, limit).then(null, function () {
    return searchDesktop(keyword, page, limit)
  })
}

// ---------- 移动端 musicu（iMusic 验证过的配方：unsigned + 安卓 UA + 完整 comm） ----------
// 2026-09 实测：web 匿名 vkey(CgiGetVkey) 已被风控(500003/104003)，
// 必须走 music.vkey.GetVkey/UrlGetVkey + 双 mid 文件名 + 移动端 comm 才能出链接。
var APP_UA = 'QQMusic 14090008(android 14)'

var hexChars = '0123456789abcdef'
function randomHex(n) {
  var s = ''
  for (var i = 0; i < n; i++) {
    s += hexChars.charAt(Math.floor(Math.random() * 16))
  }
  return s
}

// 设备指纹（iMusic 同款生成规则，导入时随机生成一次并固定）
var GUID = randomHex(32)
var TS = String(Date.now())
var QIMEI = (randomHex(24) + TS).slice(-32)
var QIMEI36 = randomHex(20) + TS
var AID = randomHex(16)

function appComm() {
  var c = {
    ct: 11,
    cv: 14090008,
    v: 14090008,
    chid: '10003505',
    tmeAppID: 'qqmusic',
    QIMEI: QIMEI,
    QIMEI36: QIMEI36,
    OpenUDID: GUID,
    OpenUDID2: GUID,
    udid: GUID,
    aid: AID,
    os_ver: '14',
    phonetype: 'Android',
    devicelevel: '34',
    newdevicelevel: '34',
    rom: 'google/webview',
  }
  if (COOKIE) {
    // COOKIE 形如: uin=o12345;qm_keyst=Q_H_L_xxx（登录后自动注入；
    // uin 可能带 o 前缀也可能不带，两种都要兼容）
    var uinMatch = COOKIE.match(/uin=o?([0-9]+)/)
    var keyMatch = COOKIE.match(/qm_keyst=([^;]+)/)
    if (uinMatch) c.uin = uinMatch[1]
    if (keyMatch) c.qm_keyst = keyMatch[1]
    if (uinMatch && keyMatch) c.tmeLoginType = 2
  }
  return c
}

function appMusicu(module_, method, param) {
  var payload = { comm: appComm() }
  payload.req_0 = { module: module_, method: method, param: param }
  return http('https://u.y.qq.com/cgi-bin/musicu.fcg', {
    method: 'POST',
    body: JSON.stringify(payload),
    headers: { 'User-Agent': APP_UA, 'Content-Type': 'application/json' },
  }).then(function (resp) {
    var body = resp.body
    if (typeof body === 'string') body = JSON.parse(body)
    return body.req_0 || {}
  })
}

// ---------- 播放链接 ----------
function pickSip(sips) {
  var sip = ''
  for (var s = 0; sips && s < sips.length; s++) {
    if (String(sips[s]).indexOf('https') === 0) {
      sip = sips[s]
      break
    }
  }
  if (!sip && sips && sips.length) sip = sips[0]
  if (!sip) sip = 'https://dl.stream.qqmusic.qq.com/'
  return sip
}

// 逐个音质请求（UrlGetVkey 批量只有首个文件名返回 purl），失败顺链降级
function tryChain(types, idx, mid) {
  if (idx >= types.length) {
    return Promise.reject(new Error('无可用播放链接（版权限制或已下架）'))
  }
  var spec = FORMAT_MAP[types[idx]]
  var param = {
    uin: '',
    filename: [spec[0] + mid + mid + spec[1]],
    guid: GUID.toLowerCase(),
    songmid: [mid],
    songtype: [0],
    ctx: 0,
  }
  return appMusicu('music.vkey.GetVkey', 'UrlGetVkey', param).then(
    function (resp) {
      var d = (resp && resp.data) || {}
      var item = (d.midurlinfo && d.midurlinfo[0]) || {}
      if (item.purl) {
        return { type: types[idx], url: pickSip(d.sip) + item.purl }
      }
      return tryChain(types, idx + 1, mid)
    },
    function () {
      return tryChain(types, idx + 1, mid)
    }
  )
}

function handleMusicUrl(info) {
  var musicInfo = info.musicInfo || {}
  var mid = musicInfo.songmid || musicInfo.mid || ''
  if (!mid) return Promise.reject(new Error('缺少 songmid'))
  var requested = info.type || '320k'
  if (!QUALITY_CHAINS[requested]) requested = '320k'

  // 组链：请求音质优先，附全局兜底（去重）
  var chain = []
  function pushType(t) {
    if (chain.indexOf(t) === -1 && FORMAT_MAP[t]) chain.push(t)
  }
  QUALITY_CHAINS[requested].forEach(pushType)
  ULTIMATE_FALLBACK.forEach(pushType)
  return tryChain(chain, 0, mid)
}

// ---------- 歌词 ----------
function decodeLyricFields(data) {
  var result = {}
  if (data.lyric) result.lyric = base64Decode(data.lyric)
  if (data.trans) result.tlyric = base64Decode(data.trans)
  if (!result.lyric) throw new Error('歌词为空')
  return result
}

function lyricFromMusicu(musicInfo) {
  return musicu('req', 'music.musichallSong.PlayLyricInfo', 'GetPlayLyricInfo', {
    songMID: musicInfo.songmid || '',
    songID: parseInt(musicInfo.songId, 10) || 0,
    crypto: 'text',
  }).then(function (data) {
    if (data.code !== 0 || !data.data) throw new Error('歌词接口失败')
    return decodeLyricFields(data.data)
  })
}

function lyricFromLegacy(musicInfo) {
  var url =
    'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg' +
    '?pcachetime=' + Date.now() +
    '&songmid=' + (musicInfo.songmid || '') +
    '&g_tk=5381&loginUin=0&hostUin=0&format=json&inCharset=utf-8' +
    '&outCharset=utf-8&notice=0&platform=yqq.json&needNewCode=0'
  return http(url, { headers: { Referer: 'https://y.qq.com/portal/player.html' } }).then(
    function (resp) {
      var body = resp.body
      if (typeof body === 'string') body = JSON.parse(body)
      if (!body || body.retcode !== 0 || !body.lyric) throw new Error('歌词为空')
      return { lyric: base64Decode(body.lyric) }
    }
  )
}

function handleLyric(info) {
  var musicInfo = info.musicInfo || {}
  if (!musicInfo.songmid) return Promise.reject(new Error('缺少 songmid'))
  return lyricFromMusicu(musicInfo).then(null, function () {
    return lyricFromLegacy(musicInfo)
  })
}

// ---------- 封面 ----------
function handlePic(info) {
  var musicInfo = info.musicInfo || {}
  var albumMid = musicInfo.albumMid || musicInfo.albummid
  if (albumMid) {
    return Promise.resolve(
      'https://y.gtimg.cn/music/photo_new/T002R500x500M000' + albumMid + '.jpg'
    )
  }
  if (!musicInfo.name) return Promise.resolve('')
  return handleSearch({
    keyword: musicInfo.name + ' ' + (musicInfo.singer || ''),
    page: 1,
    limit: 3,
  }).then(
    function (result) {
      var list = result.list || []
      for (var i = 0; i < list.length; i++) {
        if (list[i].albumMid) {
          return (
            'https://y.gtimg.cn/music/photo_new/T002R500x500M000' +
            list[i].albumMid +
            '.jpg'
          )
        }
      }
      return ''
    },
    function () {
      return ''
    }
  )
}

// ---------- 注册 ----------
lx.on(EVENT_NAMES.request, function (payload) {
  var action = payload.action
  var info = payload.info || {}
  if (action === 'musicUrl') return handleMusicUrl(info)
  if (action === 'musicSearch' || action === 'search') return handleSearch(info)
  if (action === 'lyric' || action === 'musicLyric') return handleLyric(info)
  if (action === 'pic' || action === 'musicPic') return handlePic(info)
  return Promise.reject(new Error('不支持的动作: ' + action))
})

lx.send(EVENT_NAMES.inited, {
  openDevTools: false,
  sources: {
    tx: {
      name: 'QQ音乐',
      type: 'music',
      actions: ['musicUrl', 'musicSearch', 'musicLyric', 'musicPic'],
      // 与内置 QQ 源音质档位保持一致（脚本内 QUALITY_CHAINS 已覆盖这些档位，
      // 未开放的会顺链降级到最接近的可播音质）
      qualitys: ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'master'],
    },
  },
})
