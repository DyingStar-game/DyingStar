using System;
using System.Collections.Generic;
using Godot;

/// <summary>Integer-only model-v6 hot loop. The GDScript solver remains the reference and
/// validates commands/checkpoints. Geometry and every operation use identical signed integers.</summary>
public partial class LavaStepNative : RefCounted
{
    private long[] _areas = Array.Empty<long>(), _capacities = Array.Empty<long>();
    private long[] _bed = Array.Empty<long>(), _widths = Array.Empty<long>(), _distances = Array.Empty<long>(), _levels = Array.Empty<long>();
    private int[] _neighbors = Array.Empty<int>();
    private long[] _flux = Array.Empty<long>(), _dv = Array.Empty<long>(), _de = Array.Empty<long>(), _da = Array.Empty<long>(), _incoming = Array.Empty<long>();
    private long[] _vx = Array.Empty<long>(), _vz = Array.Empty<long>();
    private byte[] _mask = Array.Empty<byte>();
    private int _width;
    private long[] _muLut = Array.Empty<long>(), _roots = Array.Empty<long>();
    private long _ambient, _solidus, _black, _maxAge, _maxVelocity, _idleTicks;
    public long GetModelSchema() => 6;

    public void Configure(int width, long[] areas, long[] capacities, int[] neighbors,
        long[] widths, long[] distances, long[] levels, long[] muLut, long[] roots, long[] limits)
    {
        _width=width; _areas=areas; _capacities=capacities; _neighbors=neighbors;
        _widths=widths; _distances=distances; _levels=levels;
        // Model constants come from the reference, not a second copied table.
        _muLut=muLut; _roots=roots;
        _ambient=limits[0]; _solidus=limits[1]; _black=limits[2];
        _maxAge=limits[3]; _maxVelocity=limits[4]; _idleTicks=limits[5];
        int n=areas.Length;
        _flux=new long[n*4]; _dv=new long[n]; _de=new long[n]; _da=new long[n]; _incoming=new long[n];
        _vx=new long[n]; _vz=new long[n]; _mask=new byte[n];
    }

    public Godot.Collections.Dictionary Step(int[] wet, long[] bed, long[] volume, long[] energy, long[] exposure,
        long[] epochs, long[] p, long[] rims)
    {
        _bed=bed;
        // Only hot cells enter. Wake a cold receiver if a real transfer reaches it.
        // Injection and the complete post-eruption cleanup remain shared in GDScript.
        long viscosity=p[0], yield=p[1], gravity=p[2], lastSource=p[4], next=p[5];
        bool cooling=p[3]!=0;
        int crater=(int)p[6];
        long pressure=lastSource>=0 ? p[7]*Math.Clamp(lastSource+_idleTicks+60-next,0L,60L)/60 : 0;
        Array.Clear(_flux); Array.Clear(_dv); Array.Clear(_de); Array.Clear(_da); Array.Clear(_incoming);
        Array.Clear(_vx); Array.Clear(_vz); Array.Clear(_mask);
        foreach(int i in wet) _mask[i]=1;
        int limited=0;
        foreach(int i in wet)
        {
            long v=volume[i]; if(v==0) continue;
            long t=_ambient+energy[i]/v; if(t<=_solidus) continue;
            long surface=_bed[i]*1000+v*1000000000/_areas[i]+(i/_width<crater ? pressure*1000 : 0);
            long mu=MuAt(t,viscosity);
            long cold=Math.Clamp(11500-t,0L,2000L);
            long tau=yield+12*yield*cold*cold/4000000;
            long total=0;
            for(int d=0;d<4;d++)
            {
                int k=i*4+d, j=_neighbors[k]; if(j<0) continue;
                long neighbor=_bed[j]*1000+volume[j]*1000000000/_areas[j]+(j/_width<crater ? pressure*1000 : 0);
                long head=surface-neighbor;
                long barrier=Math.Max(_bed[i],_bed[j]);
                if(crater>0 && Math.Min(i/_width,j/_width)==crater-1 && Math.Max(i/_width,j/_width)==crater)
                    barrier=Math.Max(barrier,rims[i%_width]);
                long face=Math.Min(v*1000000/_areas[i],(surface-barrier*1000)/1000);
                if(head<1000 || face<1) continue;
                long stress=(2600*gravity/1000)*face*(head/1000)/(1000*_distances[k]);
                if(stress<=tau) continue;
                long b=tau*65536/stress, b3=(b*b/65536)*b/65536;
                long factor=65536-3*b/2+b3/2;
                long denominator=3*mu, faceFactor=face*1000;
                long speed=stress>(100000000*denominator)/faceFactor ? 100000000 : stress*faceFactor/denominator;
                speed=speed*factor/65536;
                long level=MulDiv(head/1000,_levels[k],1000000)*48/100;
                long amount=Math.Min(_capacities[i],Math.Min((speed*face/1000)*_widths[k]/10000000,level));
                _flux[k]=amount; total+=amount;
            }
            long limit=v*45/100;
            if(total>limit) limited++;
            for(int d=0;d<4;d++)
            {
                int k=i*4+d;
                long amount=_flux[k];
                if(total>limit) { amount=amount*limit/total; _flux[k]=amount; }
                if(amount>0) _incoming[_neighbors[k]]+=amount;
            }
        }
        var born=new List<int>();
        var woken=new List<int>();
        foreach(int i in wet)
        {
            if(volume[i]==0) continue;
            for(int d=0;d<4;d++)
            {
                int k=i*4+d; long amount=_flux[k]; if(amount==0) continue;
                int j=_neighbors[k]; long room=_capacities[j]-volume[j];
                if(_incoming[j]>room) amount=amount*room/_incoming[j];
                if(amount>0 && volume[j]==0 && _mask[j]==0) { _mask[j]=1; born.Add(j); }
                if(amount>0 && epochs[j]>=0)
                {
                    long elapsed=next-1-epochs[j];
                    if(cooling) energy[j]=Math.Max(0,energy[j]-elapsed*Math.Max(1,volume[j]/10));
                    exposure[j]=Math.Min(exposure[j]+elapsed*volume[j],volume[j]*_maxAge);
                    epochs[j]=-1;
                    woken.Add(j);
                }
                long heat=MulDiv(energy[i],amount,volume[i]);
                long age=MulDiv(exposure[i],amount,volume[i]);
                _dv[i]-=amount; _dv[j]+=amount; _de[i]-=heat; _de[j]+=heat; _da[i]-=age; _da[j]+=age;
                long speed=Math.Min(_maxVelocity,MulDiv(amount,_distances[k]*10000,volume[i]));
                if(d<2) _vx[i]+=d==0 ? -speed : speed;
                else _vz[i]+=d==2 ? -speed : speed;
            }
        }
        var updated=new List<int>(wet.Length+born.Count+woken.Count);
        updated.AddRange(wet); updated.AddRange(born); updated.AddRange(woken);
        foreach(int i in updated)
        {
            volume[i]+=_dv[i]; energy[i]+=_de[i];
            exposure[i]=Math.Min(exposure[i]+_da[i]+volume[i],volume[i]*_maxAge);
            if(volume[i]==0 || !cooling) continue;
            long t=_ambient+energy[i]/volume[i];
            if(t<=_black)
            {
                energy[i]=Math.Max(0,energy[i]-Math.Max(1,volume[i]/10));
                continue;
            }
            long second=exposure[i]/volume[i]/10;
            long root=second<_roots.Length ? _roots[(int)second] : IntegerSqrt((second+1)*10000);
            long kelvin=(t+2731)/10, k2=kelvin*kelvin;
            long radiation=Math.Max(0,k2*k2-7370050801)*53865/1000000000000;
            long insulation=1000+root*8, dt=t-_ambient;
            long air=(radiation+8*dt/10)*1000/insulation, ground=1200*dt/root;
            long loss=(air+ground)*_areas[i]/3640000000;
            energy[i]=Math.Max(0,energy[i]-loss);
        }
        var active=new List<int>();
        var coldCells=new List<int>();
        foreach(int i in updated)
        {
            if(_ambient+energy[i]/volume[i]<=_black)
            {
                epochs[i]=next; _vx[i]=0; _vz[i]=0;
                coldCells.Add(i);
            }
            else { epochs[i]=-1; active.Add(i); }
        }
        return new Godot.Collections.Dictionary {
            {"volume",volume},{"energy",energy},{"exposure",exposure},{"vx",_vx},{"vz",_vz},
            {"born",born.ToArray()},{"limited",limited},{"epochs",epochs},
            {"updated",updated.ToArray()},{"active",active.ToArray()},
            {"cold",coldCells.ToArray()},{"woken",woken.ToArray()}
        };
    }

    private long MuAt(long t,long reference)
    {
        long offset=Math.Clamp(t,9500L,14000L)-9500;
        int index=(int)Math.Min(offset/100,_muLut.Length-2);
        long f=offset-index*100;
        long multiplier=_muLut[index]+(_muLut[index+1]-_muLut[index])*f/100;
        return Math.Max(1,reference*multiplier/1000000);
    }
    private static long IntegerSqrt(long value)
    { long x=value,y=(x+1)/2; while(y<x) { x=y; y=(x+value/x)/2; } return x; }
    private static long MulDiv(long a,long b,long divisor)
    {
        if(a==0 || b==0) return 0;
        if(a<=long.MaxValue/b) return a*b/divisor;
        long whole=a/divisor, rem=a%divisor;
        if(rem<=long.MaxValue/b) return whole*b+rem*b/divisor;
        long result=0,carry=0;
        while(b>0)
        {
            if((b&1)!=0) { result+=whole; carry+=rem; if(carry>=divisor) { carry-=divisor; result++; } }
            b>>=1;
            if(b>0) { whole*=2; rem*=2; if(rem>=divisor) { rem-=divisor; whole++; } }
        }
        return result;
    }
}
