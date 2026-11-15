/** 表情包库：rawfile/stickers/ 下的 GIF，文件名就是表情的名字，跟文件一一对应 */
export interface StickerDef {
  file: string;
  tag: string;
}

export const STICKERS: StickerDef[] = [
  { file: '不服气.gif', tag: '不服气' },
  { file: '开心.gif', tag: '开心' },
  { file: '点赞.gif', tag: '点赞' },
  { file: '委屈.gif', tag: '委屈' },
  { file: '生气.gif', tag: '生气' },
  { file: '无语.gif', tag: '无语' },
  { file: '困了.gif', tag: '困了' },
  { file: '谢谢.gif', tag: '谢谢' },
  { file: '收到.gif', tag: '收到！' },
  { file: '抱抱.gif', tag: '抱抱' },
  { file: '震惊.gif', tag: '震惊' },
  { file: '再见.gif', tag: '再见' },
  { file: '喜欢.gif', tag: '喜欢' },
  { file: '对不起.gif', tag: '对不起' },
  { file: '开饭啦.gif', tag: '开饭啦' },
  { file: '加油.gif', tag: '加油' },
  { file: '早安.gif', tag: '早安' },
  { file: '晚安.gif', tag: '晚安' },
  { file: '在吗.gif', tag: '在吗' },
  { file: '来了.gif', tag: '来了' },
  { file: '等一下.gif', tag: '等一下' },
  { file: '马上到.gif', tag: '马上到' },
  { file: '没问题.gif', tag: '没问题' },
  { file: '好的.gif', tag: '好的' },
  { file: '明白.gif', tag: '明白' },
  { file: '安排了.gif', tag: '安排了' },
  { file: '辛苦了.gif', tag: '辛苦了' },
  { file: '拜托了.gif', tag: '拜托了' },
  { file: '笑死.gif', tag: '笑死' },
  { file: '哈哈哈.gif', tag: '哈哈哈' },
  { file: '绷不住了.gif', tag: '绷不住了' },
  { file: '离谱.gif', tag: '离谱' },
  { file: '真的假的.gif', tag: '真的假的' },
  { file: '啊这.gif', tag: '啊这' },
  { file: '好家伙.gif', tag: '好家伙' },
  { file: '我裂开了.gif', tag: '我裂开了' },
  { file: '麻了.gif', tag: '麻了' },
  { file: '破防了.gif', tag: '破防了' },
  { file: '红温了.gif', tag: '红温了' },
  { file: '那咋了.gif', tag: '那咋了' },
  { file: '已老实.gif', tag: '已老实' },
  { file: '求放过.gif', tag: '求放过' },
  { file: '我没事.gif', tag: '我没事' },
  { file: '不想说话.gif', tag: '不想说话' },
  { file: '静静看戏.gif', tag: '静静看戏' },
  { file: '吃瓜.gif', tag: '吃瓜' },
  { file: '拿捏了.gif', tag: '拿捏了' },
  { file: '我懂你.gif', tag: '我懂你' },
  { file: '尊嘟假嘟.gif', tag: '尊嘟假嘟' },
  { file: '你礼貌吗.gif', tag: '你礼貌吗' },
  { file: '有被冒犯.gif', tag: '有被冒犯' },
  { file: '大可不必.gif', tag: '大可不必' },
  { file: '退退退.gif', tag: '退退退' },
  { file: '想你了.gif', tag: '想你了' },
  { file: '贴贴.gif', tag: '贴贴' },
  { file: '亲亲.gif', tag: '亲亲' },
  { file: '爱你.gif', tag: '爱你' },
  { file: '摸摸头.gif', tag: '摸摸头' },
  { file: '别难过.gif', tag: '别难过' },
  { file: '有我在.gif', tag: '有我在' },
  { file: '给你花.gif', tag: '给你花' },
  { file: '上班了.gif', tag: '上班了' },
  { file: '下班啦.gif', tag: '下班啦' },
  { file: '摸鱼中.gif', tag: '摸鱼中' },
  { file: '赶工中.gif', tag: '赶工中' },
  { file: '我尽力了.gif', tag: '我尽力了' },
  { file: '不想上班.gif', tag: '不想上班' },
  { file: '开会中.gif', tag: '开会中' },
  { file: '我太难了.gif', tag: '我太难了' },
  { file: 'CPU烧了.gif', tag: 'CPU烧了' },
  { file: '救命.gif', tag: '救命' },
  { file: '让我缓缓.gif', tag: '让我缓缓' },
  { file: '充电中.gif', tag: '充电中' },
  { file: '干饭人.gif', tag: '干饭人' },
  { file: '先吃一口.gif', tag: '先吃一口' },
  { file: '咖啡续命.gif', tag: '咖啡续命' },
  { file: '发工资啦.gif', tag: '发工资啦' },
  { file: '疑惑.gif', tag: '疑惑' },
  { file: '嫌弃.gif', tag: '嫌弃' },
  { file: '紧张.gif', tag: '紧张' },
  { file: '期待.gif', tag: '期待' },
  { file: '害羞.gif', tag: '害羞' },
  { file: '偷笑.gif', tag: '偷笑' },
  { file: '得意.gif', tag: '得意' },
  { file: '心累.gif', tag: '心累' },
  { file: '好累.gif', tag: '好累' },
  { file: '饿了.gif', tag: '饿了' },
  { file: '撑了.gif', tag: '撑了' },
  { file: '冻住了.gif', tag: '冻住了' },
  { file: '热化了.gif', tag: '热化了' },
  { file: '满血复活.gif', tag: '满血复活' },
  { file: '撤退.gif', tag: '撤退' },
  { file: '确认眼神.gif', tag: '确认眼神' },
  { file: '恭喜.gif', tag: '恭喜' },
  { file: '发财啦.gif', tag: '发财啦' },
  { file: '接好运.gif', tag: '接好运' },
  { file: '欧气满满.gif', tag: '欧气满满' },
  { file: '好运加一.gif', tag: '好运加一' },
  { file: '生日快乐.gif', tag: '生日快乐' },
  { file: '周末快乐.gif', tag: '周末快乐' },
];

/**
 * 老版本把文件名存成了 s001.gif 这种，聊天记录里还留着；
 * 按序号映射回新名字，历史表情包才不会变成裂图。
 */
export function migrateStickerName(name: string): string {
  const m: RegExpMatchArray | null = name.match(/^s(\d{3})\.gif$/);
  if (m === null) {
    return name;
  }
  const idx: number = parseInt(m[1], 10) - 1;
  if (idx >= 0 && idx < STICKERS.length) {
    return STICKERS[idx].file;
  }
  return name;
}
