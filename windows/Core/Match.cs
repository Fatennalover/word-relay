namespace WordRelay.Core;

public sealed record SuggestionOptions(int Count = 5, int MinimumLength = 3, int CustomLimit = 100,
    IReadOnlyList<string>? CustomWords = null)
{
    public static string? Word(string text)
    {
        string normalized = text.Trim().ToLowerInvariant();
        return normalized.Length is >= 2 and <= 40 && normalized.All(char.IsAsciiLetter) ? normalized : null;
    }

    public static List<string> ParseCustom(string text) => text.Split([' ', '\t', '\r', '\n', ','],
        StringSplitOptions.RemoveEmptyEntries).Select(Word).OfType<string>().Distinct().ToList();

    public IReadOnlyList<string> Favorites => CustomWords ?? Array.Empty<string>();
}

public sealed class Lexicon
{
    private readonly HashSet<string> known;
    private readonly Dictionary<string, List<string>> index = new();
    public int Count => known.Count;

    public Lexicon(string common, string expanded)
    {
        var first = Parse(common);
        var extra = Parse(expanded);
        extra.ExceptWith(first);
        known = new HashSet<string>(first, StringComparer.Ordinal);
        known.UnionWith(extra);
        foreach (string word in Rank(first).Concat(Rank(extra)))
        {
            for (int length = 1; length <= Math.Min(word.Length, 5); length++)
            {
                string key = word[..length];
                if (!index.TryGetValue(key, out var matches)) index[key] = matches = [];
                matches.Add(word);
            }
        }
    }

    private static HashSet<string> Parse(string words) => words.Split('\n', StringSplitOptions.RemoveEmptyEntries)
        .Select(word => word.Trim().ToLowerInvariant())
        .Where(word => word.Length >= 2 && word.All(char.IsAsciiLetter)).ToHashSet(StringComparer.Ordinal);

    private static IOrderedEnumerable<string> Rank(HashSet<string> words) => words.OrderBy(word => word.Length +
        (word.EndsWith('s') || word.EndsWith("ed", StringComparison.Ordinal) || word.EndsWith("ing", StringComparison.Ordinal) ? 3 : 0))
        .ThenBy(word => word, StringComparer.Ordinal);

    public bool Contains(string word) => known.Contains(word);

    public List<string> Search(string prefix, HashSet<string> excluded, SuggestionOptions settings, int count, int customCount = 0)
    {
        if (prefix.Length == 0 || count <= 0) return [];
        var favorites = settings.Favorites.ToHashSet(StringComparer.Ordinal);
        bool Eligible(string word) => word.Length >= settings.MinimumLength && !excluded.Contains(word) &&
            word.StartsWith(prefix, StringComparison.Ordinal);

        var results = settings.Favorites.Where(Eligible)
            .Take(Math.Min(count, Math.Max(0, settings.CustomLimit - customCount))).ToList();
        if (results.Count < count && index.TryGetValue(prefix[..Math.Min(5, prefix.Length)], out var group))
            results.AddRange(group.Where(word => !favorites.Contains(word) && Eligible(word)).Take(count - results.Count));
        return results;
    }
}

public enum MatchPhase { Waiting, Turn, Between, Finished }
public enum PlayedOrigin { Submitted, Observed, Confirmed, Manual }
public sealed record Played(string Word, PlayedOrigin Origin);

public sealed class Match
{
    private readonly Lexicon lexicon;
    private readonly HashSet<string> used = new(StringComparer.Ordinal);
    private readonly HashSet<string> shown = new(StringComparer.Ordinal);
    private readonly HashSet<string> earlier = new(StringComparer.Ordinal);
    private double? lastClock, clockAt, resetAt, blankAt, noHudAt;
    private (double Time, double Value)? clockJump;
    private double finishedAt, candidateAt;
    private string candidate = "";
    private int repeats;
    private string? typedWord;
    private SuggestionOptions options;

    public Match(Lexicon lexicon, SuggestionOptions options)
    {
        this.lexicon = lexicon;
        this.options = options;
    }

    public MatchPhase Phase { get; private set; }
    public string Prefix { get; private set; } = "";
    public string PreviousPrefix { get; private set; } = "";
    public string? FinishReason { get; private set; }
    public List<string> Suggestions { get; } = [];
    public List<string> History { get; } = [];
    public List<Played> PlayedWords { get; } = [];
    public int UsedCount => used.Count;
    public int Turns { get; private set; }
    public int Revision { get; private set; }
    public bool CanCycle { get; private set; }
    public double? LiveSeconds { get; private set; }
    public double? SecondsAt { get; private set; }
    public double TurnAt { get; private set; }

    public double? Remaining(double now, int fallback) => Phase != MatchPhase.Turn ? null :
        Math.Max(0, LiveSeconds is double seconds && SecondsAt is double readAt
            ? seconds - (now - readAt) : fallback - (now - TurnAt));

    public bool ClockActive(double now) => lastClock is double clock && now - clock <= 1.05;

    public void Observe(Reading reading, double now, int endAfter)
    {
        bool live = reading.ClockVisible || reading.Seconds > 0;
        if (live)
        {
            lastClock = now;
            noHudAt = null;
            if (Phase == MatchPhase.Between) SetPhase(MatchPhase.Turn);
        }
        if (reading.Seconds is double seconds) UpdateClock(seconds, now);

        if (reading.Row is null)
        {
            repeats = 0;
            if (reading.TilesPresent || Phase is MatchPhase.Waiting or MatchPhase.Finished) return;
            blankAt ??= now;
            if (!live && lastClock.HasValue) noHudAt ??= now;
            if (ClockActive(now)) return;
            bool hudGone = noHudAt is double gone && now - gone >= Math.Min(3, endAfter);
            if (hudGone || now - blankAt >= endAfter)
                Finish(hudGone ? "Game screen closed" : $"No tiles for {endAfter}s", now);
            else if (now - blankAt >= .6 && !(LiveSeconds > now - SecondsAt))
                SetPhase(MatchPhase.Between);
            return;
        }

        string letters = reading.Row.ToLowerInvariant();
        double gap = blankAt is double blank ? now - blank : 0;
        if (letters != candidate || repeats == 0)
        {
            candidate = letters;
            candidateAt = now;
            repeats = 1;
        }
        else repeats = Math.Min(repeats + 1, 8);
        noHudAt = null;
        if (repeats < 2) return;
        blankAt = null;

        if (Phase == MatchPhase.Finished)
        {
            if (now - finishedAt < .65) return;
            if (live) lastClock = now;
            SetPhase(MatchPhase.Waiting);
        }

        bool same = letters == Prefix;
        bool extension = Prefix.Length > 0 && !same && letters.StartsWith(Prefix, StringComparison.Ordinal);
        bool fragment = !same && Prefix.StartsWith(letters, StringComparison.Ordinal);
        bool changed = !same && !extension && !fragment;
        bool different = changed && repeats >= 3 && now - candidateAt >= .19;
        bool carry = typedWord is not null && typedWord != letters && letters != Prefix &&
            typedWord.EndsWith(letters, StringComparison.Ordinal);
        bool reset = resetAt is double resetTime && now - resetTime < 1.5 &&
            (!extension || candidateAt >= resetTime - .5);

        if (Phase == MatchPhase.Waiting || reset || carry || different || gap >= .40 && (changed || Phase == MatchPhase.Between))
        {
            if (carry) Record(typedWord!, PlayedOrigin.Observed);
            double? clock = reading.Seconds ??
                (LiveSeconds is double last && SecondsAt is double at && now - at <= .38 ? Math.Max(0, last - (now - at)) : null);
            SetPrompt(letters, now, clock);
        }
        else
        {
            if (extension && IsKnown(letters)) typedWord = letters;
            if (Phase == MatchPhase.Between) SetPhase(MatchPhase.Turn);
        }
    }

    private void UpdateClock(double value, double now)
    {
        if (LiveSeconds is double old && clockAt is double sampleAt)
        {
            double elapsed = now - sampleAt;
            double projected = Math.Max(0, old - elapsed);
            bool jump = value > old + .70 || elapsed > .85 && value >= old - .2 && value > projected + 1.1;
            if (jump)
            {
                if (clockJump is not { } pending || now - pending.Time > 1.2 ||
                    value < pending.Value - 1.8 || value > pending.Value + .35)
                {
                    clockJump = (now, value);
                    return;
                }
                resetAt = now;
            }
            else if (value > old + .45 || value < projected - 2)
            {
                clockJump = null;
                return;
            }
        }
        clockJump = null;
        LiveSeconds = value;
        SecondsAt = clockAt = now;
    }

    public void SetPrompt(string letters, double now, double? seconds = null)
    {
        if (Phase == MatchPhase.Finished) Reset();
        PreviousPrefix = Prefix;
        Prefix = letters.ToLowerInvariant();
        Phase = MatchPhase.Turn;
        Turns++;
        TurnAt = now;
        LiveSeconds = seconds;
        SecondsAt = clockAt = seconds.HasValue ? now : null;
        clockJump = null;
        resetAt = null;
        typedWord = null;
        RestartSuggestions();
    }

    public bool IsKnown(string word) => lexicon.Contains(word) || options.Favorites.Contains(word);

    public void ApplyPreferences(SuggestionOptions value)
    {
        options = value;
        RestartSuggestions();
    }

    public void Next()
    {
        if (!CanCycle) return;
        earlier.UnionWith(Suggestions);
        Suggestions.Clear();
        Fill();
        if (Suggestions.Count == 0) RestartSuggestions();
    }

    private void RestartSuggestions()
    {
        earlier.Clear();
        Suggestions.Clear();
        Fill();
    }

    private void Fill()
    {
        if (Phase is not (MatchPhase.Turn or MatchPhase.Between)) return;
        var excluded = new HashSet<string>(used, StringComparer.Ordinal);
        excluded.UnionWith(earlier);
        excluded.UnionWith(Suggestions);
        var matches = lexicon.Search(Prefix, excluded, options, options.Count - Suggestions.Count,
                                     Suggestions.Count(options.Favorites.Contains));
        foreach (string word in matches)
        {
            Suggestions.Add(word);
            if (shown.Add(word)) History.Add(word);
        }
        excluded = new HashSet<string>(used, StringComparer.Ordinal);
        excluded.UnionWith(Suggestions);
        CanCycle = lexicon.Search(Prefix, excluded, options, 1).Count != 0;
        Revision++;
    }

    public void Record(string value, PlayedOrigin origin)
    {
        if (SuggestionOptions.Word(value) is not { } word) return;
        int index = PlayedWords.FindIndex(entry => entry.Word == word);
        if (index < 0) PlayedWords.Add(new Played(word, origin));
        else
        {
            var previous = PlayedWords[index];
            var combined = (previous.Origin, origin) switch
            {
                (PlayedOrigin.Submitted, PlayedOrigin.Observed) or (PlayedOrigin.Observed, PlayedOrigin.Submitted)
                    => PlayedOrigin.Confirmed,
                (PlayedOrigin.Observed, PlayedOrigin.Manual) => PlayedOrigin.Manual,
                _ => previous.Origin
            };
            PlayedWords[index] = new Played(word, combined);
        }
        Revision++;
        if (origin == PlayedOrigin.Observed || !used.Add(word)) return;
        Suggestions.Remove(word);
        Fill();
        if (Suggestions.Count == 0 && earlier.Count != 0) RestartSuggestions();
    }

    public void Undo(string word)
    {
        PlayedWords.RemoveAll(entry => entry.Word == word);
        Revision++;
        if (used.Remove(word)) RestartSuggestions();
    }

    public void Pause()
    {
        candidate = "";
        repeats = 0;
        blankAt = noHudAt = lastClock = resetAt = null;
        clockJump = null;
        typedWord = null;
    }

    public void Reset()
    {
        Pause();
        Phase = MatchPhase.Waiting;
        Prefix = PreviousPrefix = "";
        FinishReason = null;
        Turns = 0;
        LiveSeconds = SecondsAt = clockAt = null;
        History.Clear();
        PlayedWords.Clear();
        Suggestions.Clear();
        used.Clear();
        shown.Clear();
        earlier.Clear();
        CanCycle = false;
        Revision++;
    }

    private void SetPhase(MatchPhase phase)
    {
        if (Phase == phase) return;
        Phase = phase;
        Revision++;
    }

    private void Finish(string reason, double now)
    {
        Reset();
        Phase = MatchPhase.Finished;
        FinishReason = reason;
        finishedAt = now;
    }
}
