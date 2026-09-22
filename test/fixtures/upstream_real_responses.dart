/// 上游(https://api-new.bugpk.com/api/dyjx)两条**真实**应答,只把长 URL 截短了。
///
/// 抓取时间 2026-09-19,用来钉住字段名 —— 上游改结构时这些用例会先红。
/// 字段清单(实测):
///   data: type / title / desc / author{name,id,avatar} / cover / url / label /
///         quality / size / bit_rate / width / height / video_backup[] /
///         images[] (纯地址字符串) / live_photo[]{image,video} / music{}
///   video_backup[]: size / size_label / label / quality / url / bit_rate /
///                   width / height / format / codec / quality_type / gear_name
library;

/// 普通视频帖:url 是主地址(原画),ideo_backup 里是 720P / 540P。
const Map<String, dynamic> kRealDouyinVideo = <String, dynamic>{
  'code': 200,
  'msg': '解析成功-eo',
  'data': <String, dynamic>{
    'type': 'video',
    'title': '【8KHDR素材】极北之境的色彩重塑：挪威冬日高画质摄影巡礼 #素材 #视频素材 #摄影 #旅游 #风景',
    'desc': '【8KHDR素材】极北之境的色彩重塑：挪威冬日高画质摄影巡礼 #素材 #视频素材 #摄影 #旅游 #风景',
    'cover': 'https://p3-sign.douyinpic.com/tos-cn-p-0015/os4B7EGeLdWHFrurY7f8ACXBcg&truncated=1',
    'url': 'https://v3-dy-a-x.ixigua.com/dde570300cb2ebb6ec42972e4e8db752/6ac09a70&truncated=1',
    'label': '原画',
    'quality': 'original',
    'size': 7807454953,
    'bit_rate': 34698694,
    'width': 7680,
    'height': 3210,
    'size_label': '7.27GB',
    'author': <String, dynamic>{
      'name': '8K视界',
      'id': '7674499594818339899',
      'avatar': 'https://p3.douyinpic.com/aweme/100x100/aweme-avatar/tos-cn-i-0813c000-&truncated=1',
    },
    'video_backup': <dynamic>[
      <String, dynamic>{
        'label': '720P高清',
        'quality': '720p',
        'url': 'https://v6-hscy.ixigua.com/4ed519c4dadbddbadb23b0ff937568aa/6aae3380/v&truncated=1',
        'bit_rate': 1678555,
        'size': 377687084,
        'size_label': '360.19MB',
        'width': 1722,
        'height': 720,
        'format': 'mp4',
        'codec': 'h264',
      },
      <String, dynamic>{
        'label': '540P',
        'quality': '540p',
        'url': 'https://v6-hscy.ixigua.com/d6b21ecd4b8dd5cefb46a9502de2e7d1/6aae3380/v&truncated=1',
        'bit_rate': 1294152,
        'size': 291193686,
        'size_label': '277.7MB',
        'width': 1378,
        'height': 576,
        'format': 'mp4',
        'codec': 'h264',
      },
    ],
    'images': <dynamic>[],
    'live_photo': <dynamic>[],
    'music': <String, dynamic>{
      'title': 'BGM',
      'url': 'https://sf6-cdn-tos.douyinstatic.com/obj/ies-music/7677420145308011318&truncated=1',
    },
  },
};

/// 实况帖:type = live,url 是空的,媒体全在 images + live_photo 里。
const Map<String, dynamic> kRealDouyinLive = <String, dynamic>{
  'code': 200,
  'msg': '解析成功-eo',
  'data': <String, dynamic>{
    'type': 'live',
    'title': '神的睡觉方式',
    'desc': '神的睡觉方式',
    'author': <String, dynamic>{
      'name': '多少u才算够',
      'id': '2546086583214797',
      'avatar': 'https://p3-pc.douyinpic.com/aweme/100x100/aweme-avatar/tos-cn-avt-0015&truncated=1',
    },
    'cover': 'https://p3-pc-sign.douyinpic.com/tos-cn-p-0015/oYvqkDeYdAuUB2hVAQLmreM&truncated=1',
    'url': null,
    'images': <dynamic>[
      'https://p3-pc-sign.douyinpic.com/tos-cn-i-0813c001/oMFIAApKEFAEaqAgQ9I&truncated=1',
    ],
    'live_photo': <dynamic>[
      <String, dynamic>{
        'image': 'https://p3-pc-sign.douyinpic.com/tos-cn-i-0813c001/oMFIAApKEFAEaqAgQ9I&truncated=1',
        'video': 'https://v3-chameleon.usergrowth.com.cn/28ce05729facde6081a91639cf79c2c&truncated=1',
      },
    ],
    'video_backup': <dynamic>[],
    'music': <String, dynamic>{
      'title': 'BGM',
      'url': 'https://sf11-cdn-tos.douyinstatic.com/obj/ies-music/768414468907470314&truncated=1',
    },
  },
};

/// 快手真实应答(https://api-new.bugpk.com/api/ksjx),只把长 URL 截短了。
///
/// 抓取时间 2026-09-19。和抖音那两条**同一套结构**,但字段是省着给的:
///   - 根上没有 cover / size / label / bit_rate(抖音都有)
///   - video_backup[] 只有 url / label / quality / bit_rate / width / height / codec
///   - 而且同一条 720P 给了**两遍**,两个地址只差 query 里的签名
/// 这几条差异都是映射里专门处理过的,所以单独留一份夹具。
const Map<String, dynamic> kRealKuaishouVideo = <String, dynamic>{
  'code': 200,
  'msg': '解析成功-esa',
  'data': <String, dynamic>{
    'type': 'video',
    'title': '你在找的 拼多多下载教程来了，点击左下角即可更新安装，拼多多薅羊毛啦， 一元拼多多搜 专区闭眼买~聚划算 真实有效👍#拼多多 #拼多多一元秒杀 #捡漏薅羊毛',
    'desc': '你在找的 拼多多下载教程来了，点击左下角即可更新安装，拼多多薅羊毛啦， 一元拼多多搜 专区闭眼买~聚划算 真实有效👍#拼多多 #拼多多一元秒杀 #捡漏薅羊毛',
    'author': <String, dynamic>{
      'name': '沐沐-游戏推荐',
      'id': '2319047939',
      'avatar': '',
    },
    'url': 'https://tymov2.a.kwimgs.com/upic/2025/01/08/08/BMjAyNTAxMDgwODUzMDdfMj&truncated=1',
    'quality': '原画',
    'duration': 4,
    'video_backup': <dynamic>[
      <String, dynamic>{
        'label': '高清',
        'quality': '720p',
        'url': 'https://k0u7cyeeyf5yc2zw240exb1x9801x406x800xx3z.djvod.ndcimgs.com/upi&truncated=1',
        'bit_rate': 266000,
        'width': 720,
        'height': 1280,
        'codec': 'avc',
      },
      <String, dynamic>{
        'label': '高清',
        'quality': '720p',
        'url': 'https://v4.oskwai.com/upic/2025/01/08/08/BMjAyNTAxMDgwODUzMDdfMjMxOTA0&truncated=1',
        'bit_rate': 266000,
        'width': 720,
        'height': 1280,
        'codec': 'avc',
      },
    ],
  },
};
