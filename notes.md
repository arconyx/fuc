HEADER

BEGIN MESSAGE BODY
FOR EACH CREATION
  WITH CACHE
    backdated work | new work | new chapter of
    work url | chapter url
  END CACHE
  
  (work title | chapter title) word count
  UNLESS SEEN WORK
    authors
  END UNLESS

  IF CHAPTER & CHAPTER SUMMARY EXISTS
    chapter summary
  END IF

  UNLESS SEEN WORK
    WITH CACHE
      chapters:
      fandom:
      rating:
      warnings:
      IF EXISTS relationships:
      IF EXISTS characters:
      IF EXISTS: additional tags
      IF EXISTS: series:
    END CACHE
  END UNLESS

  UNLESS SEEN WORK SUMMARY | WORK SUMMARY DOES NOT EXIST
    work summary
  END UNLESS

  IF MORE WORKS TO PROCESS
    text divider
  END IF
END LOOP
END MESSAGE BODY
    
BEGIN MESSAGE FOOTER
  footer stuff
END MESSAGE FOOTER
    
Notes:
Footer starts with
```


-----------------------------------------
````
But the update templates inserts a third leading blank line

The header is
```
  
Archive of Our Own
=========================================


```
