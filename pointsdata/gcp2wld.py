#!/usr/bin/env python
"""
gcps2wld.py
-----------
Ground Control Points to WorldFile using Affine Transformation, Affine5
(without skew) and Similarity.

Created by Klokan Petr Pridal, algorithms translated from Java, project
MapAnalyst - originally written by Bernhard Jenny from ETH Zurich
(MapAnalyst: src/ika/transformation/ TransformAffine6.java,
TransformAffine5.java, TransfrormHelmert.java)

Description of the algorithms is available in (Chapter: Affine5, page 19):

Beineke, D. (2001) Verfahren zur Genauigkeitsanalyse fur Altkarten.
Studiengang Geodasie und Geoinformation. PhD thesis. Munchen,
Universitat der Bundeswehr, 155 pp. [Corrigendum].
http://www.unibw.de/ipk/karto-en/publications/pubbeineke-en/books/
docbeineke-en/down1/at_download

Note: More efficient would be usage of 'numpy' python matrix library, but we
depend on a pure python matrix calculation, because of the limits of the
Google App Engine hosting, where we intend to use these functions.

Development carried out thanks to R&D grant DC08P02OUK006 - Old Maps Online
(www.oldmapsonline.org) from Ministry of Culture of the Czech Republic

Copyright (c) 2008 OldMapsOnline.org. All rights reserved.
"""

__version__ = "0.1"

import sys
from optparse import OptionParser

# import numpy
from matfunc import Mat

import math

def main(argv=None):
        if argv is None:
                argv = sys.argv[1:]
                
        parser = OptionParser(description=__doc__, version=__version__)
        parser.add_option('-i','--input',
                action="store", dest="inputfile", default="",
                metavar="FILE",
                help="Read list of ground control points from a FILE")
        parser.add_option("--similar", action="store_true", dest="similar")
        parser.add_option("--noskew", action="store_true", dest="noskew")
        parser.add_option("-v", action="store_true", dest="verbose")
        
        #parser.set_defaults(verbose=True)
        (options, args) = parser.parse_args( args=argv)
        
        if len(args):
                parser.error("incorrect number of arguments, use --help")
        
        if not options.inputfile:
                parser.error("no gcps specified, use --help")

        if options.verbose:
                print "reading %s..." % options.inputfile

        destSet = []
        sourceSet = []
        for line in open(options.inputfile, 'r'):
                destSet.append( map( float, line.split()[:2] ) )
                sourceSet.append( map( float, line.split()[2:4] ) )

        # print(destSet)
        # print(sourceSet)

        numberOfPoints = min( len(destSet), len(sourceSet))
        # print numberOfPoints

        # Compute centres of gravity of the two point sets.
        ## Overflow? Maybe better to use: max() min() and middle point?
        #cxDst = min( [dst[0] for dst in destSet] )
        cxDst, cyDst, cxSrc, cySrc = 0,0,0,0
        for i in range(numberOfPoints):
                cxDst += destSet[i][0]
                cyDst += destSet[i][1]
                cxSrc += sourceSet[i][0]
                cySrc += sourceSet[i][1]
        cxDst /= numberOfPoints
        cyDst /= numberOfPoints
        cxSrc /= numberOfPoints
        cySrc /= numberOfPoints

        #print cxDst, cyDst, cxSrc, cySrc

        if not (options.similar or options.noskew):
                
                if options.verbose:
                        print "- affine transformation"

                # create matrices x, y, and A.
                x = Mat( [[dst[0]-cxDst for dst in destSet]]).tr()
                y = Mat( [[dst[1]-cyDst for dst in destSet]]).tr()
                A = Mat( [ [1., src[0]-cxSrc, src[1]-cySrc] for src in sourceSet] )

                At = A.tr()
                Q =  At.mmul(A).inverse()
                a = Q.mmul(At).mmul(x)
                b = Q.mmul(At).mmul(y)

                a1 = a[1][0]
                a2 = a[2][0]
                a3 = b[1][0]
                a4 = b[2][0]

                print a1
                print a3
                print a2
                print a4
                print cxDst - a1*cxSrc - a2*cySrc
                print cyDst - a3*cxSrc - a4*cySrc
                sys.exit(0)
                
        else:
                if options.verbose:
                        print "- similarity transformation"
                
                # compute a1 and a2
                sumX1_times_x2, sumY1_times_y2 = 0, 0
                sumx2_times_x2, sumy2_times_y2 = 0, 0
                sumY1_times_x2, sumX1_times_y2 = 0, 0
                
                for i in range(numberOfPoints):
                        x2 = sourceSet[i][0] - cxSrc
                        y2 = sourceSet[i][1] - cySrc
                        sumX1_times_x2 += destSet[i][0] * x2
                        sumY1_times_y2 += destSet[i][1] * y2
                        sumx2_times_x2 += x2 * x2
                        sumy2_times_y2 += y2 * y2
                        sumY1_times_x2 += destSet[i][1] * x2
                        sumX1_times_y2 += destSet[i][0] * y2
                
                a1 = (sumX1_times_x2+sumY1_times_y2)/(sumx2_times_x2+sumy2_times_y2)
                a2 = (sumY1_times_x2-sumX1_times_y2)/(sumx2_times_x2+sumy2_times_y2)

                if options.similar:
                        print a1
                        print a2
                        print -a2
                        print a1
                        print cxDst - a1*cxSrc + a2*cySrc
                        print cyDst - a2*cxSrc - a1*cySrc
                        sys.exit(0)

                if options.verbose:
                        print "- affine5 transformation (without skew)"

                # we need iteration - starting from similarity

                # indexes to access values in the array params
                TRANSX, TRANSY, SCALEX, SCALEY, ROT = 0,1,2,3,4

                # The tolerance that is used to determine whether a new improvement for the
                # parameters is small enough to stop the computations.
                TOLERANCE = 0.000001

                params = [0,0,0,0,0]
                params[TRANSX] = 0 # close to 0, since both sets
                params[TRANSY] = 0 # of points are centered around 0
                params[SCALEX] = math.sqrt(a1*a1+a2*a2) # similarity
                params[SCALEY] = params[SCALEX]
                rot = math.atan2(a2, a1)
                if (rot < 0.):
                        rot += math.pi * 2.
                params[ROT] = rot

                dx = [0,0,0,0,0]
                dxprev = [1,1,1,1,1]
                
                while (abs(dx[0]-dxprev[0]) > TOLERANCE or
                       abs(dx[1]-dxprev[1]) > TOLERANCE or
                       abs(dx[2]-dxprev[2]) > TOLERANCE or
                       abs(dx[3]-dxprev[3]) > TOLERANCE or
                       abs(dx[4]-dxprev[4]) > TOLERANCE):

                        cosRot = math.cos(params[ROT])
                        sinRot = math.sin(params[ROT])
                        
                        array_A = []
                        array_l = []

                        for i in range(numberOfPoints):

                                xCosRot = cosRot*sourceSet[i][0]-cxSrc
                                xSinRot = sinRot*sourceSet[i][0]-cxSrc
                                yCosRot = cosRot*sourceSet[i][1]-cySrc
                                ySinRot = sinRot*sourceSet[i][1]-cySrc

                                estimationX = params[TRANSX] + params[SCALEX]*xCosRot - params[SCALEY]*ySinRot
                                estimationY = params[TRANSY] + params[SCALEX]*xSinRot + params[SCALEY]*yCosRot

                                array_l.append( [destSet[i][0] - cxDst - estimationX] )
                                array_l.append( [destSet[i][1] - cyDst - estimationY] )

                                array_A.append( [1, 0, xCosRot, -ySinRot, -(destSet[i][1]-cyDst)+params[TRANSY] ])
                                array_A.append( [0, 1, xSinRot, yCosRot, (destSet[i][0]-cxDst)-params[TRANSX] ])

                        l = Mat(array_l)
                        A = Mat(array_A)
                        At = A.tr()

                        Q = At.mmul(A).inverse()
                        x = Q.mmul( At.mmul(l) )

                        dxprev = dx
                        dx = [ x[j][0] for j in range(5) ]
                        params = [ params[j]+dx[j] for j in range(5) ] 
                        
                        #print dx
                        
                cosRot = math.cos(params[ROT])
                sinRot = math.sin(params[ROT])
                print params[SCALEX]*cosRot
                print params[SCALEX]*sinRot
                print -params[SCALEY]*sinRot
                print params[SCALEY]*cosRot
                print cxDst - params[SCALEX]*cosRot*cxSrc + params[SCALEY]*sinRot*cySrc
                print cyDst - params[SCALEX]*sinRot*cxSrc - params[SCALEY]*cosRot*cySrc


if __name__ == "__main__":
        sys.exit(main())
        #sys.exit(main(["--input=gcps.txt", "--noskew"]))

