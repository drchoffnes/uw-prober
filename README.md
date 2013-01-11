uw-prober
=========================

Network measurement helpers. Data collected from them are stored at gs://m-lab_revtr/

Files will are uploaded as revtr_$CURR_DATE.txt, where $CURR_DATE is the result of `date +%F`. Each line is a comma-separated list of values for a reverse traceroute measurement. The fields are described below, and are generated from the table at the end of the email.

- Destination (int IP) [This is where we are measuring a reverse path from.]
- Source (int IP)
- Date (string timestamp)
- Hops (int IP) [There are thirty entries. If the value is 0, there are two cases: If this occurs between two non-zero values, there is no response from the hop. If a sequence of 0's occurs as the end of a measurement, they are unused entries. This occurs because we used a fixed-size table in the database.)
- Hop type (int) [There are thirty entries; the first hop type corresponds to the first IP in the above 'Hops' section. The hop types are listed below.]

Types are:
Record Route = 1
Spoofed Record Route = 2
Prespecified Timestamp = 3
Spoofed Prespecified Timestamp= 4
Spoofed Prespecified Timestamp with Zero Stamp = 5
Spoofed Prespecified Timestamp with Zero Stamp Double Stamp = 6
Assumed Symmetry from Forward Traceroute = 7
Intersection from Traceroute toward Source = 8
Destination hop = 9

The last four fields are not statistical information and you can ignore them.
