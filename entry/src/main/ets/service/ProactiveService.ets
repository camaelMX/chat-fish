import { reminderAgentManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 黏人程度 */
export const STICK_CLUNGY: string = 'clungy';
export const STICK_NATURAL: string = 'natural';
export const STICK_QUIET: string = 'quiet';

/** 通知内容显示方式 */
export const NOTIFY_TEXT: string = 'text';
export const NOTIFY_HINT: string = 'hint';
export const NOTIFY_HIDDEN: string = 'hidden';

const HINT_TEXT: string = 'TA 想你了';
const PROACTIVE_NOTIFICATION_ID: number = 20260;

/** 安静时段（分钟，从 0 点算） */
export const DEFAULT_QUIET_START: number = 30;    // 00:30
export const DEFAULT_QUIET_END: number = 480;     // 08:00

/**
 * 主动消息的排期。
 * 系统不允许 App 在后台长期跑定时器，所以：
 * - 前台：页面用 tick() 轮询，到点直接发；
 * - 后台：用系统提醒（reminderAgent）到点弹通知，点开回到 App 再补进时间线。
 */
export class ProactiveService {
  /** 第 n 次主动找他的最小间隔（分钟，从上次说话算起） */
  private static gaps(mode: string): number[] {
    if (mode === STICK_CLUNGY) {
      return [120, 240, 480];   // 2h → 4h → 8h，一天最多 3 次
    }
    if (mode === STICK_NATURAL) {
      return [240];             // 4h，一天最多 1 次
    }
    return [];                  // 克制：不主动
  }

  private static maxPerDay(mode: string): number {
    if (mode === STICK_CLUNGY) {
      return 3;
    }
    if (mode === STICK_NATURAL) {
      return 1;
    }
    return 0;
  }

  private static dayKey(at: number): string {
    const d: Date = new Date(at);
    const m: string = (d.getMonth() + 1).toString().padStart(2, '0');
    const day: string = d.getDate().toString().padStart(2, '0');
    return d.getFullYear().toString() + m + day;
  }

  private static minutesOfDay(at: number): number {
    const d: Date = new Date(at);
    return d.getHours() * 60 + d.getMinutes();
  }

  /** 是否处于安静时段，返回 true 表示现在不该打扰 */
  static isQuiet(at: number, startMin: number, endMin: number): boolean {
    const m: number = ProactiveService.minutesOfDay(at);
    if (startMin === endMin) {
      return false;
    }
    if (startMin < endMin) {
      return m >= startMin && m < endMin;
    }
    // 跨零点，例如 23:30 - 08:00
    return m >= startMin || m < endMin;
  }

  /** 把时间推到安静时段结束 */
  static pushOutOfQuiet(at: number, startMin: number, endMin: number): number {
    if (!ProactiveService.isQuiet(at, startMin, endMin)) {
      return at;
    }
    const d: Date = new Date(at);
    d.setHours(Math.floor(endMin / 60), endMin % 60, 0, 0);
    if (d.getTime() <= at) {
      d.setDate(d.getDate() + 1);
    }
    return d.getTime();
  }

  /**
   * 计算下一次主动消息的时间点。
   * 返回 0 表示不需要排期（克制模式 / 今天已经够次数 / 没有可用 Key）。
   */
  static nextDueAt(lastActiveAt: number, lastProactiveAt: number, todayCount: number,
    mode: string, quietStart: number, quietEnd: number, now: number): number {
    const gaps: number[] = ProactiveService.gaps(mode);
    const maxPerDay: number = ProactiveService.maxPerDay(mode);
    if (gaps.length === 0 || maxPerDay === 0) {
      return 0;
    }
    if (todayCount >= maxPerDay) {
      // 今天额度用完，等明天安静时段结束后再说
      const tomorrow: Date = new Date(now);
      tomorrow.setDate(tomorrow.getDate() + 1);
      tomorrow.setHours(Math.floor(quietEnd / 60), quietEnd % 60, 0, 0);
      return tomorrow.getTime();
    }
    const idx: number = Math.min(todayCount, gaps.length - 1);
    const base: number = Math.max(lastActiveAt, lastProactiveAt);
    let due: number = base + gaps[idx] * 60000;
    if (due <= now) {
      // 已经超时（比如很久没开 App），别一进来就弹，
      // 给一段缓冲让人先自己说句话
      due = now + 20 * 60000;
    }
    return ProactiveService.pushOutOfQuiet(due, quietStart, quietEnd);
  }

  /**
   * 排一个系统提醒。到点会在通知栏弹出来，点一下回到 App。
   * 返回 reminderId，0 表示失败（没有权限或系统拒绝）。
   */
  static async schedule(ctx: common.UIAbilityContext, dueAt: number, herName: string,
    notifyMode: string, text: string): Promise<number> {
    try {
      const enabled: boolean = await notificationManager.isNotificationEnabled();
      if (!enabled) {
        return 0;
      }
    } catch (e) {
      return 0;
    }
    const d: Date = new Date(dueAt);
    const dt: reminderAgentManager.LocalDateTime = {
      year: d.getFullYear(),
      month: d.getMonth() + 1,
      day: d.getDate(),
      hour: d.getHours(),
      minute: d.getMinutes(),
      second: 0
    };
    const want: reminderAgentManager.WantAgent = {
      pkgName: ctx.abilityInfo.bundleName,
      abilityName: ctx.abilityInfo.name
    };
    let content: string = HINT_TEXT;
    if (notifyMode === NOTIFY_TEXT) {
      content = text.length > 0 ? text : HINT_TEXT;
    } else if (notifyMode === NOTIFY_HIDDEN) {
      // 只显示名字，正文留空（系统要求非空，放一个空格）
      content = ' ';
    }
    const req: reminderAgentManager.ReminderRequestCalendar = {
      reminderType: reminderAgentManager.ReminderType.REMINDER_TYPE_CALENDAR,
      dateTime: dt,
      title: herName,
      content: content,
      expiredContent: content,
      notificationId: PROACTIVE_NOTIFICATION_ID,
      ringDuration: 0,
      snoozeTimes: 0,
      tapDismissed: true,
      wantAgent: want
    };
    try {
      const id: number = await reminderAgentManager.publishReminder(req);
      return id;
    } catch (e) {
      const err: BusinessError = e as BusinessError;
      console.warn('publishReminder failed: ' + err.code + ' ' + err.message);
      return 0;
    }
  }

  static async cancel(reminderId: number): Promise<void> {
    if (reminderId <= 0) {
      return;
    }
    try {
      await reminderAgentManager.cancelReminder(reminderId);
    } catch (e) {
      // 提醒可能已经触发过，取消失败无所谓
    }
  }
}
