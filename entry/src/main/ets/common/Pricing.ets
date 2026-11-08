/**
 * DeepSeek 官方计价：闲时 / 高峰。
 * 北京时间工作日 09:00–12:00、14:00–18:00 为高峰（价格 ×2），其余为闲时。
 * 官方的“错峰优惠”节假日同样适用，这里只做展示，不影响请求。
 */

interface PeakRule {
  /** 高峰开始的分钟数（0 点起） */
  start: number;
  /** 高峰结束的分钟数 */
  end: number;
}

const MORNING: PeakRule = { start: 9 * 60, end: 12 * 60 };
const AFTERNOON: PeakRule = { start: 14 * 60, end: 18 * 60 };

/** 官方价目（元 / 百万 token），闲时价。deepseek-flash 与 pro 不同，取常用档位 */
export interface Price {
  /** 输入（缓存未命中） */
  inMiss: number;
  /** 输入（缓存命中） */
  inHit: number;
  /** 输出 */
  out: number;
}

/** 官方公开价：flash 档 */
const PRICE_FLASH: Price = { inMiss: 2, inHit: 0.2, out: 3 };
/** 官方公开价：pro 档 */
const PRICE_PRO: Price = { inMiss: 4, inHit: 0.5, out: 12 };
/** 白嫖档：官方免费额度，不花钱 */
const PRICE_FREE: Price = { inMiss: 0, inHit: 0, out: 0 };

/** 已知免费模型（名字命中就算免费），智谱官方 GLM-4.x-Flash 是永久免费的 */
const FREE_MODELS: string[] = ['glm-4.7-flash', 'glm-4.5-flash', 'glm-4-flash', 'qwen3-32b-free'];

export function isFreeModel(model: string): boolean {
  const m: string = model.toLowerCase();
  for (let i: number = 0; i < FREE_MODELS.length; i++) {
    if (m.indexOf(FREE_MODELS[i]) >= 0) {
      return true;
    }
  }
  return false;
}

export function priceOf(model: string): Price {
  const m: string = model.toLowerCase();
  if (isFreeModel(m)) {
    return PRICE_FREE;
  }
  if (m.indexOf('pro') >= 0) {
    return PRICE_PRO;
  }
  return PRICE_FLASH;
}

/** 2026 年法定节假日（仅用于“错峰优惠照常”的说明，不做调休计算） */
const HOLIDAYS_2026: string[] = [
  '01-01', '01-02', '01-03',
  '02-15', '02-16', '02-17', '02-18', '02-19', '02-20', '02-21',
  '04-04', '04-05', '04-06',
  '05-01', '05-02', '05-03', '05-04', '05-05',
  '06-19', '06-20', '06-21',
  '09-25', '09-26', '09-27',
  '10-01', '10-02', '10-03', '10-04', '10-05', '10-06', '10-07'
];

function pad2(n: number): string {
  return n < 10 ? '0' + n.toString() : n.toString();
}

export function isHoliday2026(d: Date): boolean {
  if (d.getFullYear() !== 2026) {
    return false;
  }
  const key: string = pad2(d.getMonth() + 1) + '-' + pad2(d.getDate());
  return HOLIDAYS_2026.indexOf(key) >= 0;
}

/** 周六周日算休息日 */
export function isWeekend(d: Date): boolean {
  const w: number = d.getDay();
  return w === 0 || w === 6;
}

/** 现在是否高峰价 */
export function isPeakNow(at: number): boolean {
  const d: Date = new Date(at);
  // 节假日和周末全天闲时
  if (isHoliday2026(d) || isWeekend(d)) {
    return false;
  }
  const m: number = d.getHours() * 60 + d.getMinutes();
  return (m >= MORNING.start && m < MORNING.end) || (m >= AFTERNOON.start && m < AFTERNOON.end);
}

/** 当前生效的价格倍数：高峰 ×2，闲时 ×1 */
export function rateMultiplier(at: number): number {
  return isPeakNow(at) ? 2 : 1;
}

/**
 * 估算这一次的费用（元）。
 * 注意：官方对“缓存命中”的输入单独计价，这里按传入的实际命中量算。
 */
export function estimateCost(model: string, inHit: number, inMiss: number, out: number,
  at: number): number {
  const p: Price = priceOf(model);
  const k: number = rateMultiplier(at);
  const hitYuan: number = inHit / 1000000 * p.inHit * k;
  const missYuan: number = inMiss / 1000000 * p.inMiss * k;
  const outYuan: number = out / 1000000 * p.out * k;
  return hitYuan + missYuan + outYuan;
}

/** 距离下次切换状态还有多久，用于顶部小提示 */
export function nextSwitchText(at: number): string {
  const d: Date = new Date(at);
  if (isHoliday2026(d) || isWeekend(d)) {
    return '';
  }
  const m: number = d.getHours() * 60 + d.getMinutes();
  if (m < MORNING.start) {
    return Math.ceil((MORNING.start - m) / 60).toString() + ' 小时后高峰';
  }
  if (m >= MORNING.end && m < AFTERNOON.start) {
    return '闲时';
  }
  if (m >= AFTERNOON.end) {
    return '闲时';
  }
  return '';
}
