This is the initial model routine for the massive star problem.

The file: 15m_500_sec.txt is a 15 solar mass MESA initial model, with
an aprox21 composition.

It can be converted into the subset of nuclei for aprox19 via
convert_21_to_19.py

This setup uses Ye as the primary composition variable from the initial
model in regions that are in NSE.

Note: you should ensure that the NSE conditions in the inputs file match
those of your simulation, so the model will be properly in HSE.

Also note that when running with 32768 zones, you need to do:

```
ulimit -s 16384
```

Since the arrays are put on the stack.
