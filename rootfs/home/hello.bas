10 rem breadbin basic demo
20 print "hello from basic on breadbin!"
30 for i = 1 to 5
40 print i; " squared is "; i * i
50 next i
60 gosub 100
70 end
100 print "fib:";
110 a = 0 : b = 1
120 for n = 1 to 10
130 print " "; a;
140 c = a + b : a = b : b = c
150 next n
160 print
170 return
