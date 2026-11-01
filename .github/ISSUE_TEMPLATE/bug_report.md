---
name: Bug report
about: Something doesn't work with your TrackPoint Keyboard II
labels: bug
---

**What happens / what you expected**

**Setup**
- macOS version:
- Connection: Bluetooth / USB receiver
- Keyboard firmware, if known:
- tpscroll commit or version:

**Log**
Relevant lines from `~/Library/Logs/tpscroll.log`, from `tpscroll starting` up to the problem. The log has no
keystrokes in it unless you turned on `debugKeys`. If you did, remove those lines first.

```
paste here
```

**Optional: a recording**
For protocol problems (scrolling not switching to native mode, odd reports), run the recorder and attach its log:
`./build.sh tprec && open build/TPRec.app --args --raw --no-tap --log ~/Desktop/tprec.log`
(TPRec needs its own Input Monitoring permission.) Hold middle and scroll in each direction, then tap middle.
The recording includes any keys you type while it runs, so don't type anything else during it.
