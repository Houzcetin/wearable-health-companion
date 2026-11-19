# User test protocol: five-user comparison (Stage 7)

Based on the "Five-user comparison protocol" in [PLAN.md](PLAN.md). It tests the product promise, **"See what changed from your usual in 10 seconds,"** by having the same people answer the same questions in our app and in the official Google Health (Fitbit) app.

Stage 2 measures the baseline on the official app; this run repeats it for both apps side by side so the comparison is fair.

## 1. Goal and what counts as success

- **Primary:** time to a correct answer on each task, our app versus the official app. Target: **10 seconds or less** in our app for the sleep question.
- **Secondary:** correctness, hesitation points, and whether our morning numbers match the official app's for the same day.
- **Outcome:** the top three problems found, fixed, and listed in the report (Stage 7 definition of done).

## 2. Participants and setup

- **Five** participants who wear a Fitbit Air or use an account with real data. If a real device is not available for all five: a shared or prepared account with 28+ days of data is acceptable. Write which one was used.
- **To verify before the first session** (open items in PLAN.md and SETUP.md): how all five get device access; each participant's Google account is added under Audience → Test users (limit 100); the consent screen is still in "Testing", so refresh tokens expire after 7 days, so connect them **within the week of the session** or reconnect on the day.
- Each participant must have synced their device in the Google Health app that morning, and have been connected to our app with at least 7 days of data (28 days preferred). Run **Sync now** before the session.
- One phone per participant session with both apps installed and signed in; notifications off; screen brightness fixed; the official app on its home tab, ours on Today.
- Equipment: the same phone, a stopwatch (or screen recording with a visible clock), the answer key (section 5), a printed consent form and a results sheet (section 8).
- Facilitator and observer: one person speaks, one person times and writes. The facilitator does **not** hint, point or explain while a task runs.

## 3. Tasks

The same three tasks in both apps. Read each aloud exactly as written.

| # | Task text (read aloud) | What a correct answer contains |
|---|---|---|
| T1 | "What changed in your sleep last night compared with your usual?" | Direction (more, less, or about the same) **and** roughly how much, as the app presents it. |
| T2 | "Was your resting heart rate this morning higher, lower or about the same as usual?" | The right direction, and the value or difference if the app shows it. |
| T3 | "Was your activity yesterday or today higher or lower than usual? Roughly how many steps?" | The right direction and the step count shown. |

Optional follow-up for our app only: "Pick the day that looked most unusual this month and tell me why." (opens Trends); and "Ask the coach why this week was different" to see whether they find the coach.

## 4. Order and conduct

1. **Counterbalance.** Alternate which app goes first: participants 1, 3, 5 start with the **official app**; 2 and 4 start with **ours**. Record the order.
2. **Brief them** with the script below, then the consent form (section 7). Do not describe how either app works.
3. **No practice run.** Hand over the phone with the app already open on its first screen.
4. Say "Go", read the task and **start the timer**.
5. **Stop the timer** the moment they say an answer you can compare with the key. If the answer is unclear, ask "Is that your final answer?" and stop at the first clear answer. Do not stop for thinking aloud.
6. Cap a task at **120 seconds**. Record "gave up" and the cap time.
7. Reset the phone to the first screen of that app. Repeat T2, then T3.
8. Switch apps and repeat T1–T3 in the same order.
9. Close with the questions in section 6.

Script: "I am testing the apps, not you. There are no wrong answers. Please say your answer out loud as soon as you have it, and tell me when you are confused. I will not be able to help while you are doing a task."

## 5. Measurement

- **Time:** seconds from "Go" (after the task is read) to the first clear spoken answer. One stopwatch, one person, rounded to the nearest second. Mark runs where the timer was uncertain.
- **Correctness (before the session):** the observer fills in the **answer key** for that participant from the data: last night's sleep and the 28-day typical, today's resting heart rate and typical, and the step counts, taken from our database and from the official app. Mark each answer: **correct** (direction right and number within the rounding the app shows), **partly** (direction right, number off or missing) or **wrong**.
- **Hesitation points:** write down every moment where the participant pauses for more than **3 seconds**, taps something and backs out, opens the wrong screen, asks what something means, or reads a label aloud in confusion. Note the screen and the element ("Heart card: 'usual range' unclear").
- **Number parity:** for each participant, compare our **Today** values with the official app's for the same day: sleep duration, resting heart rate and steps. Record each pair and the difference. Explain differences (different sleep definition, sync lag) where you can.
- **Quotes:** write down anything they say about trust, clarity or wording, verbatim.

## 6. After the tasks (2 minutes)

1. "Which app answered faster for you? Why?"
2. "Was anything in our app hard to understand? What did 'usual range' or 'typical' mean to you?"
3. "Would you open our app in the morning? Why or why not?"
4. Optional, 1–5: "How confident were you in your answers?" for each app.

## 7. Consent (KVKK)

Print this on one page; each participant signs before the session. Keep one copy for the team and give one to the participant.

> **Participant information and explicit consent (KVKK, Law No. 6698)**
>
> **Controller:** Wearable Health Companion student project team, [university and course], contact: [name and email].
>
> **Purpose:** to test how quickly and correctly people read sleep, heart-rate and activity information in two apps, and to improve our app. This is a course project and not a medical service.
>
> **What we collect:** your answers, task times, our notes and, only if you agree below, the daily sleep, resting heart rate and step values from your Google Health account that are needed to check your answers. We do not collect raw sensor streams, your name beside your results or any other health data. Results are recorded under a participant number such as P1.
>
> **Screen recording:** we will / will not record the phone screen (circle one). A recording shows only the apps in the test.
>
> **How long:** data is kept until the end of the course report, then deleted, within [period]. Daily values stored by the app can be deleted at any time from Settings → Delete health data. We do not share your data with others except as anonymised results in the course report.
>
> **Your rights:** under KVKK Article 11 you can ask whether we hold your data, ask for a copy, correction or deletion, and withdraw consent at any time without giving a reason and without any effect on you. You may stop the session at any time.
>
> **Explicit consent:**
> ☐ I have read this notice and agree to take part.
> ☐ I explicitly agree that my daily sleep, resting heart rate and step values may be read to check my answers.
> ☐ I agree to the screen recording (optional).
>
> Name: ____________  Participant no.: ____  Date: ______  Signature: ____________

Have a lawyer or the course supervisor review this text before use, and fill in the controller and retention details.

## 8. Results template

Copy this section per run. Times in seconds, correctness as C (correct), P (partly) or W (wrong), "—" when the user gave up.

**Participant sheet**

| Field | Value |
|---|---|
| Participant | P_ |
| Date / time | |
| Device or account | Fitbit Air / shared account |
| Days of data in our app | |
| First app | Official / Ours |
| Consent signed, recording | ☐ / ☐ |

**Answer key (fill before the session)**

| | Our app | Official app | Difference |
|---|---|---|---|
| Sleep last night | | | |
| Typical sleep (28 days) | | | |
| Resting heart rate today | | | |
| Typical resting heart rate | | | |
| Steps (the day asked about) | | | |

**Per task**

| Task | App | Time (s) | Correct (C/P/W) | Hesitation points | Notes / quotes |
|---|---|---|---|---|---|
| T1 sleep | Official | | | | |
| T1 sleep | Ours | | | | |
| T2 heart | Official | | | | |
| T2 heart | Ours | | | | |
| T3 activity | Official | | | | |
| T3 activity | Ours | | | | |

**Summary across all five participants**

| Measure | Official app | Our app |
|---|---|---|
| T1 median time (s) | | |
| T1 within 10 s (count of 5) | | |
| T2 median time (s) | | |
| T3 median time (s) | | |
| Correct answers (of 15) | | |
| Hesitation points per participant (mean) | | |
| Our values matching the official app (count of 15) | | |

**Top three problems** (decided from the hesitation points, most frequent first)

| # | Problem | Seen in (participants) | Fix | Fixed on |
|---|---|---|---|---|
| 1 | | | | |
| 2 | | | | |
| 3 | | | | |

Sort every run by the participant number, keep the raw sheets, and attach the summary to the Stage 7 report.
