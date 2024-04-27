//! Introduced in 1582 as a revision of the Julian calendar.
//!
//! Currently implemented using Euclidian Affine Transforms:
//! https://onlinelibrary.wiley.com/doi/epdf/10.1002/spe.3172
const std = @import("std");
const epoch_mod = @import("./epoch.zig");
const ComptimeDate = epoch_mod.ComptimeDate;
const IntFittingRange = std.math.IntFittingRange;
const secs_per_day = std.time.s_per_day;
const expectEqual = std.testing.expectEqual;
const assert = std.debug.assert;

/// A proleptic (projected backwards) Gregorian calendar date.
/// `epoch_` is in terms of days since 1970-01-01.
///
/// This implementation requires the `EpochDays` range cover all possible values of `YearT`.
pub fn Advanced(comptime YearT: type, comptime epoch: ComptimeDate, shift: comptime_int) type {
    return struct {
        year: Year,
        month: Month,
        day: Day,

        pub const Year = YearT;

        /// Inclusive.
        pub const min_epoch_day = daysSince(epoch, ComptimeDate.init(std.math.minInt(Year), 1, 1));
        /// Inclusive.
        pub const max_epoch_day = daysSince(epoch, ComptimeDate.init(std.math.maxInt(Year), 12, 31));

        pub const EpochDays = IntFittingRange(min_epoch_day, max_epoch_day);
        // These are used for math that should not overflow.
        const UEpochDays = std.meta.Int(
            .unsigned,
            std.math.ceilPowerOfTwoAssert(u16, @typeInfo(EpochDays).Int.bits),
        );
        const IEpochDays = std.meta.Int(.signed, @typeInfo(UEpochDays).Int.bits);
        const EpochDaysWide = std.meta.Int(
            @typeInfo(EpochDays).Int.signedness,
            @typeInfo(UEpochDays).Int.bits,
        );

        // Variables in paper.
        const K = daysSince(Computational.epoch_, epoch) + era.days * shift;
        const L = era.years * shift;

        // Type overflow checks
        comptime {
            const min_year_no_overflow = -L;
            const max_year_no_overflow = std.math.maxInt(UEpochDays) / days_in_year.numerator - L + 1;
            assert(min_year_no_overflow < std.math.minInt(Year));
            assert(max_year_no_overflow > std.math.maxInt(Year));

            const min_epoch_day_no_overflow = -K;
            const max_epoch_day_no_overflow = (std.math.maxInt(UEpochDays) - 3) / 4 - K;
            assert(min_epoch_day_no_overflow < min_epoch_day);
            assert(max_epoch_day_no_overflow > max_epoch_day);
        }

        /// Easier to count from. See section 4 of paper.
        const Computational = struct {
            year: UEpochDays,
            month: UIntFitting(14),
            day: UIntFitting(30),

            pub const epoch_ = ComptimeDate.init(0, 3, 1);

            inline fn toGregorian(self: Computational, N_Y: UIntFitting(365)) Date {
                const last_day_of_jan = 306;
                const J: UEpochDays = if (N_Y >= last_day_of_jan) 1 else 0;

                const month: MonthInt = if (J != 0) self.month - 12 else self.month;
                const year: EpochDaysWide = @bitCast(self.year +% J -% L);

                return .{
                    .year = @intCast(year),
                    .month = @enumFromInt(month),
                    .day = @as(Day, self.day) + 1,
                };
            }

            inline fn fromGregorian(date: Date) Computational {
                const month: UIntFitting(14) = date.month.numeric();
                const Widened = std.meta.Int(
                    @typeInfo(Year).Int.signedness,
                    @typeInfo(UEpochDays).Int.bits,
                );
                const widened: Widened = date.year;
                const Y_G: UEpochDays = @bitCast(widened);
                const J: UEpochDays = if (month <= 2) 1 else 0;

                return .{
                    .year = Y_G +% L -% J,
                    .month = if (J != 0) month + 12 else month,
                    .day = date.day - 1,
                };
            }
        };

        const Date = @This();

        /// May save some typing vs struct initialization.
        pub fn init(year: Year, month: Month, day: Day) Date {
            return .{ .year = year, .month = month, .day = day };
        }

        pub fn fromEpoch(days: EpochDays) Date {
            // This function is Figure 12 of the paper.
            // Besides being ported from C++, the following has changed:
            // - Seperate Year and UEpochDays types
            // - Rewrite EAFs in terms of `a` and `b`
            // - Add EAF bounds assertions
            // - Use bounded int types provided in Section 10 instead of u32 and u64
            // - Add computational calendar struct type
            // - Add comments referencing some proofs
            assert(days >= min_epoch_day);
            assert(days <= max_epoch_day);
            const mod = std.math.comptimeMod;
            const div = comptimeDivFloor;

            const widened: EpochDaysWide = days;
            const N = @as(UEpochDays, @bitCast(widened)) +% K;

            const a1 = 4;
            const b1 = 3;
            const N_1 = a1 * N + b1;
            const C = N_1 / era.days;
            const N_C: UIntFitting(36_564) = div(mod(N_1, era.days), a1);

            const N_2 = a1 * @as(UIntFitting(146_099), N_C) + b1;
            // n % 1461 == 2939745 * n % 2^32 / 2939745,
            // for all n in [0, 28825529)
            assert(N_2 < 28_825_529);
            const a2 = 2_939_745;
            const b2 = 0;
            const P_2_max = 429493804755;
            const P_2 = a2 * @as(UIntFitting(P_2_max), N_2) + b2;
            const Z: UIntFitting(99) = div(P_2, (1 << 32));
            const N_Y: UIntFitting(365) = div(mod(P_2, (1 << 32)), a2 * a1);

            // (5 * n + 461) / 153 == (2141 * n + 197913) /2^16,
            // for all n in [0, 734)
            assert(N_Y < 734);
            const a3 = 2_141;
            const b3 = 197_913;
            const N_3 = a3 * @as(UIntFitting(979_378), N_Y) + b3;

            const computational = Computational{
                .year = 100 * C + Z,
                .month = div(N_3, 1 << 16),
                .day = div(mod(N_3, (1 << 16)), a3),
            };

            return computational.toGregorian(N_Y);
        }

        pub fn toEpoch(self: Date) EpochDays {
            // This function is Figure 13 of the paper.
            const c = Computational.fromGregorian(self);
            const C = c.year / 100;

            const y_star = days_in_year.numerator * c.year / 4 - C + C / 4;
            const days_in_5mo = 31 + 30 + 31 + 30 + 31;
            const m_star = (days_in_5mo * @as(UEpochDays, c.month) - 457) / 5;
            const N = y_star + m_star + c.day;

            return @intCast(@as(IEpochDays, @bitCast(N)) - K);
        }

        pub const Duration = struct {
            year: Year,
            month: Duration.Month,
            day: Duration.Day,

            pub const Day = std.meta.Int(.signed, @typeInfo(EpochDays).Int.bits);
            pub const Month = std.meta.Int(.signed, @typeInfo(Duration.Day).Int.bits - std.math.log2_int(u16, 12));

            /// May save some typing vs struct initialization.
            pub fn init(year: Year, month: Duration.Month, day: Duration.Day) Duration {
                return .{ .year = year, .month = month, .day = day };
            }
        };

        pub fn add(self: Date, duration: Duration) Date {
            const m = duration.month + self.month.numeric() - 1;
            const y = self.year + duration.year + @divFloor(m, 12);

            const ym_epoch_day = Date{
                .year = @intCast(y),
                .month = @enumFromInt(std.math.comptimeMod(m, 12) + 1),
                .day = 1,
            };

            var epoch_days = ym_epoch_day.toEpoch();
            epoch_days += duration.day + self.day - 1;

            return fromEpoch(epoch_days);
        }

        pub const Weekday = WeekdayT;
        pub fn weekday(self: Date) Weekday {
            // 1970-01-01 is a Thursday.
            const epoch_days = self.toEpoch() +% Weekday.thu.numeric();
            return @enumFromInt(std.math.comptimeMod(epoch_days, 7));
        }
    };
}

pub fn Gregorian(comptime Year: type, comptime epoch: ComptimeDate) type {
    const shift = solveShift(Year, epoch) catch unreachable;
    return Advanced(Year, epoch, shift);
}

fn testFromToEpoch(comptime T: type) !void {
    const d1 = T{ .year = 1970, .month = .jan, .day = 1 };
    const d2 = T{ .year = 1980, .month = .jan, .day = 1 };

    try expectEqual(3_652, d2.toEpoch() - d1.toEpoch());

    // We don't have time to test converting there and back again for every possible i64/u64.
    // The paper has already proven it and written tests for i32 and u32.
    // Instead let's cycle through the first and last 1 << 16 part of each range.
    const min_epoch_day: i128 = T.min_epoch_day;
    const max_epoch_day: i128 = T.max_epoch_day;
    const diff = max_epoch_day - min_epoch_day;
    const range: usize = if (max_epoch_day - min_epoch_day > 1 << 16) 1 << 16 else @intCast(diff);
    for (0..range) |i| {
        const ii: T.IEpochDays = @intCast(i);

        const d3: T.EpochDays = @intCast(min_epoch_day + ii);
        try expectEqual(d3, T.fromEpoch(d3).toEpoch());

        const d4: T.EpochDays = @intCast(max_epoch_day - ii);
        try expectEqual(d4, T.fromEpoch(d4).toEpoch());
    }
}

test "Gregorian from and to epoch" {
    try testFromToEpoch(Gregorian(i16, epoch_mod.unix));
    try testFromToEpoch(Gregorian(i32, epoch_mod.unix));
    try testFromToEpoch(Gregorian(i64, epoch_mod.unix));
    try testFromToEpoch(Gregorian(u16, epoch_mod.unix));
    try testFromToEpoch(Gregorian(u32, epoch_mod.unix));
    try testFromToEpoch(Gregorian(u64, epoch_mod.unix));

    try testFromToEpoch(Gregorian(i16, epoch_mod.windows));
    try testFromToEpoch(Gregorian(i32, epoch_mod.windows));
    try testFromToEpoch(Gregorian(i64, epoch_mod.windows));
    try testFromToEpoch(Gregorian(u16, epoch_mod.windows));
    try testFromToEpoch(Gregorian(u32, epoch_mod.windows));
    try testFromToEpoch(Gregorian(u64, epoch_mod.windows));
}

test Gregorian {
    const T = Gregorian(i16, epoch_mod.unix);
    const d1 = T.init(1960, .jan, 1);
    const epoch = T.init(1970, .jan, 1);

    try expectEqual(365, T.init(1971, .jan, 1).toEpoch());
    try expectEqual(epoch, T.fromEpoch(0));
    try expectEqual(3_653, epoch.toEpoch() - d1.toEpoch());

    // overflow
    // $ TZ=UTC0 date -d '1970-01-01 +1 year +13 months +32 days' --iso-8601=seconds
    try expectEqual(
        T.init(1972, .mar, 4),
        T.init(1970, .jan, 1).add(T.Duration.init(1, 13, 32)),
    );
    // underflow
    // $ TZ=UTC0 date -d '1972-03-04 -10 year -13 months -32 days' --iso-8601=seconds
    try expectEqual(
        T.init(1961, .jan, 3),
        T.init(1972, .mar, 4).add(T.Duration.init(-10, -13, -32)),
    );

    // $ date -d '1970-01-01'
    try expectEqual(.thu, epoch.weekday());
    try expectEqual(.thu, epoch.add(T.Duration.init(0, 0, 7)).weekday());
    try expectEqual(.thu, epoch.add(T.Duration.init(0, 0, -7)).weekday());
    // $ date -d '1980-01-01'
    try expectEqual(.tue, T.init(1980, .jan, 1).weekday());
    // $ date -d '1960-01-01'
    try expectEqual(.fri, d1.weekday());
}

const WeekdayInt = IntFittingRange(1, 7);
pub const WeekdayT = enum(WeekdayInt) {
    mon = 1,
    tue = 2,
    wed = 3,
    thu = 4,
    fri = 5,
    sat = 6,
    sun = 7,

    pub const Int = WeekdayInt;

    /// Convenient conversion to `WeekdayInt`. mon = 1, sun = 7
    pub fn numeric(self: @This()) Int {
        return @intFromEnum(self);
    }
};

const MonthInt = IntFittingRange(1, 12);
pub const Month = enum(MonthInt) {
    jan = 1,
    feb = 2,
    mar = 3,
    apr = 4,
    may = 5,
    jun = 6,
    jul = 7,
    aug = 8,
    sep = 9,
    oct = 10,
    nov = 11,
    dec = 12,

    pub const Int = MonthInt;
    pub const Days = IntFittingRange(28, 31);

    /// Convenient conversion to `MonthInt`. jan = 1, dec = 12
    pub fn numeric(self: @This()) Int {
        return @intFromEnum(self);
    }

    pub fn days(self: @This(), is_leap_year: bool) Days {
        const m: Days = @intCast(self.numeric());
        return if (m != 2)
            30 | (m ^ (m >> 3))
        else if (is_leap_year)
            29
        else
            28;
    }
};
pub const Day = IntFittingRange(1, 31);

test Month {
    try expectEqual(31, Month.jan.days(false));
    try expectEqual(29, Month.feb.days(true));
    try expectEqual(28, Month.feb.days(false));
    try expectEqual(31, Month.mar.days(false));
    try expectEqual(30, Month.apr.days(false));
    try expectEqual(31, Month.may.days(false));
    try expectEqual(30, Month.jun.days(false));
    try expectEqual(31, Month.jul.days(false));
    try expectEqual(31, Month.aug.days(false));
    try expectEqual(30, Month.sep.days(false));
    try expectEqual(31, Month.oct.days(false));
    try expectEqual(30, Month.nov.days(false));
    try expectEqual(31, Month.dec.days(false));
}

pub fn is_leap(year: anytype) bool {
    return if (@mod(year, 25) != 0)
        year & (4 - 1) == 0
    else
        year & (16 - 1) == 0;
}

test is_leap {
    try expectEqual(false, is_leap(2095));
    try expectEqual(true, is_leap(2096));
    try expectEqual(false, is_leap(2100));
    try expectEqual(true, is_leap(2400));
}

fn daysSinceJan01(d: ComptimeDate) u16 {
    const leap = is_leap(d.year);
    var res: u16 = d.day;
    for (1..d.month + 1) |j| {
        const m: Month = @enumFromInt(j);
        res += m.days(leap);
    }

    return res;
}

pub fn daysSince(from: ComptimeDate, to: ComptimeDate) comptime_int {
    const eras = @divFloor(to.year - from.year, era.years);
    comptime var res: comptime_int = eras * era.days;

    var i = from.year + eras * era.years;
    while (i < to.year) : (i += 1) {
        res += if (is_leap(i)) 366 else 365;
    }

    res += @intCast(daysSinceJan01(to));
    res -= @intCast(daysSinceJan01(from));

    return res;
}

test daysSince {
    try expectEqual(366, daysSince(ComptimeDate.init(2000, 1, 1), ComptimeDate.init(2001, 1, 1)));
    try expectEqual(146_097, daysSince(ComptimeDate.init(0, 1, 1), ComptimeDate.init(400, 1, 1)));
    try expectEqual(146_097 + 366, daysSince(ComptimeDate.init(0, 1, 1), ComptimeDate.init(401, 1, 1)));
    try expectEqual(23_936_532, daysSince(ComptimeDate.init(std.math.minInt(i16), 1, 1), ComptimeDate.init(std.math.maxInt(i16) + 1, 1, 1)));
}

/// The Gregorian calendar repeats every 400 years.
const era = struct {
    pub const years = 400;
    pub const days = 146_097;
};

/// Number of days between two consecutive March equinoxes
const days_in_year = struct {
    const actual = 365.2424;
    // .0001 days per year of error.
    const numerator = 1_461;
    const denominator = 4;
};

fn UIntFitting(to: comptime_int) type {
    return IntFittingRange(0, to);
}

/// Finds minimum epoch shift that covers the range:
/// [std.math.minInt(Year), std.math.maxInt(Year)]
fn solveShift(comptime Year: type, comptime epoch: ComptimeDate) !comptime_int {
    // TODO: linear system of equations solver
    _ = epoch;
    return @divFloor(std.math.maxInt(Year), era.years) + 1;
}

test solveShift {
    const epoch = epoch_mod.unix;
    try expectEqual(82, try solveShift(i16, epoch));
    try expectEqual(5_368_710, try solveShift(i32, epoch));
    try expectEqual(23_058_430_092_136_940, try solveShift(i64, epoch));
}

fn ComptimeDiv(comptime Num: type, comptime divisor: comptime_int) type {
    const info = @typeInfo(Num).Int;
    return std.meta.Int(info.signedness, info.bits - std.math.log2(divisor));
}

/// Return the quotient of `num` with the smallest integer type
fn comptimeDivFloor(num: anytype, comptime divisor: comptime_int) ComptimeDiv(@TypeOf(num), divisor) {
    return @intCast(@divFloor(num, divisor));
}

test comptimeDivFloor {
    try std.testing.expectEqual(@as(u13, 100), comptimeDivFloor(@as(u16, 1000), 10));
}